/* 10-replmon.sql  (runs on the publisher/distributor)
   ReplMon: a self-measuring, self-healing layer over transactional replication.
     - Tracer token collector: end-to-end latency split publisher->distributor and distributor->subscriber
     - Health check (every 30s): agent stopped, data conflicts (20598 / 2627 / 2601), latency SLO
     - Drift check (every 5 min): rowcount + checksum, then key-level diff with a tracer-token barrier
     - Auto-repair: key-based reconcile of the subscriber from the publisher, agent restart
     - Incident log with detect / repair / resolve timestamps (the chaos tests read these)
   Tokens: {{PUBLISHER_DB}} {{PUBLICATION}} {{LATENCY_SLO_SEC}} */
USE master;
GO
IF DB_ID(N'ReplMon') IS NULL CREATE DATABASE ReplMon;
GO
ALTER DATABASE ReplMon SET RECOVERY SIMPLE;
GO
USE ReplMon;
GO
/* ------------------------------------------------------------------ tables */
IF OBJECT_ID(N'dbo.Settings') IS NULL
CREATE TABLE dbo.Settings (Name sysname PRIMARY KEY, Value nvarchar(256) NOT NULL);

IF OBJECT_ID(N'dbo.Subscriber') IS NULL
CREATE TABLE dbo.Subscriber (
    SubscriberName sysname       NOT NULL PRIMARY KEY,   -- as used in sp_addsubscription
    SubscriberDb   sysname       NOT NULL UNIQUE,        -- distinct per subscriber => one agent each
    LinkedServer   sysname       NOT NULL,
    Tier           varchar(10)   NOT NULL,               -- on-prem | cloud
    IsActive       bit           NOT NULL DEFAULT 1,
    RegisteredAt   datetime2(3)  NOT NULL DEFAULT GETDATE()
);

IF OBJECT_ID(N'dbo.TracerLatency') IS NULL
CREATE TABLE dbo.TracerLatency (
    TracerId          int          NOT NULL,
    SubscriberName    sysname      NOT NULL,
    PublisherCommit   datetime     NOT NULL,
    DistributorCommit datetime     NOT NULL,
    SubscriberCommit  datetime     NOT NULL,
    DistLatencyMs     int          NOT NULL,   -- publisher -> distributor (Log Reader)
    SubLatencyMs      int          NOT NULL,   -- distributor -> subscriber (Distribution Agent)
    TotalLatencyMs    AS (DistLatencyMs + SubLatencyMs) PERSISTED,
    CONSTRAINT PK_TracerLatency PRIMARY KEY (TracerId, SubscriberName)
);

IF OBJECT_ID(N'dbo.DriftCheck') IS NULL
CREATE TABLE dbo.DriftCheck (
    CheckId        bigint IDENTITY PRIMARY KEY,
    CheckedAt      datetime2(3) NOT NULL DEFAULT GETDATE(),
    SubscriberName sysname      NOT NULL,
    TableName      nvarchar(300) NOT NULL,
    PubRows        bigint NULL, SubRows bigint NULL,
    PubChecksum    int NULL,    SubChecksum int NULL,
    Outcome        varchar(20)  NOT NULL,      -- Clean | InFlight | Drift | Inconclusive
    DriftKeys      int          NOT NULL DEFAULT 0
);

IF OBJECT_ID(N'dbo.DriftKey') IS NULL
CREATE TABLE dbo.DriftKey (
    CheckId   bigint        NOT NULL,
    KeyValue  nvarchar(400) NOT NULL,
    Kind      varchar(10)   NOT NULL,          -- Missing | Extra | Changed
    PubHash   int NULL, SubHash int NULL
);

IF OBJECT_ID(N'dbo.Incident') IS NULL
CREATE TABLE dbo.Incident (
    IncidentId     int IDENTITY PRIMARY KEY,
    Kind           varchar(20)   NOT NULL,     -- AgentStopped | DataConflict | SilentDrift | LatencyBreach
    SubscriberName sysname       NOT NULL,
    DetectedAt     datetime2(3)  NOT NULL DEFAULT GETDATE(),
    Diagnosis      nvarchar(1000) NULL,
    Action         nvarchar(1000) NULL,
    ActionAt       datetime2(3)  NULL,
    ResolvedAt     datetime2(3)  NULL
);

/* One row per repaired row: what the subscriber had, what the publisher had, what was written,
   and the replicated command that failed. Rows are stored as JSON so any table fits. */
IF OBJECT_ID(N'dbo.RepairLog') IS NULL
CREATE TABLE dbo.RepairLog (
    RepairId          int IDENTITY PRIMARY KEY,
    IncidentId        int           NULL,
    RepairedAt        datetime2(3)  NOT NULL DEFAULT GETDATE(),
    SubscriberName    sysname       NOT NULL,
    TableName         nvarchar(300) NOT NULL,
    KeyValues         nvarchar(400) NOT NULL,
    Mode              varchar(10)   NOT NULL,        -- sync | delete
    ErrorCode         sysname       NULL,
    ErrorText         nvarchar(1000) NULL,
    FailedCommand     nvarchar(max) NULL,            -- decoded with sp_browsereplcmds when available
    SubscriberBefore  nvarchar(max) NULL,            -- NULL = row was missing at the subscriber
    PublisherRow      nvarchar(max) NULL,            -- source of truth at repair time
    SubscriberAfter   nvarchar(max) NULL
);

/* Resilience targets per chaos scenario, in seconds from injection. Edit to match your SLOs. */
IF OBJECT_ID(N'dbo.ChaosTarget') IS NULL
CREATE TABLE dbo.ChaosTarget (
    Scenario         varchar(20) NOT NULL PRIMARY KEY,
    DetectTargetSec  int         NOT NULL,
    RecoverTargetSec int         NOT NULL,
    Description      nvarchar(300) NOT NULL
);
GO
MERGE dbo.ChaosTarget AS t
USING (VALUES
    ('AgentStopped',          60, 120, N'Distribution Agent job stopped. Expect: detect, restart the job, backlog drains.'),
    ('RowNotFound',          120, 180, N'Row deleted at the subscriber, then updated at the publisher (20598). Expect: restore the row, restart the agent.'),
    ('DuplicateKey',         120, 180, N'Stray subscriber row holds a unique value a new publisher row needs (2627). Expect: publisher judges it stray, delete it, restart the agent.'),
    ('SilentDrift',           60,  90, N'Row changed directly at the subscriber; no error is ever raised. Drift check triggered on demand. Expect: find and resync that row.'),
    ('SilentDriftScheduled', 360, 420, N'As SilentDrift, but waiting for the 5-minute drift schedule: the real-world worst case.')
) AS s (Scenario, DetectTargetSec, RecoverTargetSec, Description)
ON t.Scenario = s.Scenario
WHEN NOT MATCHED THEN INSERT VALUES (s.Scenario, s.DetectTargetSec, s.RecoverTargetSec, s.Description);
GO
IF OBJECT_ID(N'dbo.ChaosRun') IS NULL
CREATE TABLE dbo.ChaosRun (
    RunId          int IDENTITY PRIMARY KEY,
    Scenario       varchar(20)  NOT NULL,
    SubscriberName sysname      NOT NULL,
    InjectedAt     datetime2(3) NOT NULL,
    DetectedAt     datetime2(3) NULL,
    RepairedAt     datetime2(3) NULL,
    RecoveredAt    datetime2(3) NULL,
    DetectSec      AS (DATEDIFF(MILLISECOND, InjectedAt, DetectedAt) / 1000.0),
    RecoverSec     AS (DATEDIFF(MILLISECOND, InjectedAt, RecoveredAt) / 1000.0),
    Notes          nvarchar(1000) NULL,
    Result         varchar(10)  NULL,      -- Running | Passed | Failed
    IncidentId     int          NULL
);
GO
-- upgrade an older ChaosRun in place
IF COL_LENGTH(N'dbo.ChaosRun', N'Result') IS NULL
    ALTER TABLE dbo.ChaosRun ADD Result varchar(10) NULL, IncidentId int NULL;
GO
-- runs recorded before Result existed were only saved when they passed
UPDATE dbo.ChaosRun SET Result = 'Passed' WHERE Result IS NULL AND RecoveredAt IS NOT NULL;
GO
MERGE dbo.Settings AS t
USING (VALUES (N'PublisherDb', N'{{PUBLISHER_DB}}'), (N'Publication', N'{{PUBLICATION}}'),
              (N'LatencySloSec', N'{{LATENCY_SLO_SEC}}'), (N'AutoRepair', N'1'),
              (N'BarrierTimeoutSec', N'120')) AS s (Name, Value)
ON t.Name = s.Name
WHEN MATCHED THEN UPDATE SET Value = s.Value
WHEN NOT MATCHED THEN INSERT (Name, Value) VALUES (s.Name, s.Value);
GO
CREATE OR ALTER FUNCTION dbo.fn_Setting (@Name sysname) RETURNS nvarchar(256)
AS BEGIN RETURN (SELECT Value FROM dbo.Settings WHERE Name = @Name); END;
GO
/* Subscriber -> its distribution agent and Agent job */
CREATE OR ALTER VIEW dbo.vSubscriberAgent
AS
SELECT s.SubscriberName, s.SubscriberDb, s.LinkedServer, s.Tier, s.RegisteredAt,
       a.id AS AgentId, a.name AS AgentName,
       CONVERT(uniqueidentifier, a.job_id) AS JobId, j.name AS JobName
FROM dbo.Subscriber s
JOIN distribution.dbo.MSdistribution_agents a
  ON a.subscriber_db = s.SubscriberDb
 AND a.publisher_db  = dbo.fn_Setting(N'PublisherDb')
 AND a.publication   = dbo.fn_Setting(N'Publication')
LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = CONVERT(uniqueidentifier, a.job_id)
WHERE s.IsActive = 1;
GO
/* ------------------------------------------------------------------ incidents */
CREATE OR ALTER PROCEDURE dbo.usp_OpenIncident
    @Kind varchar(20), @SubscriberName sysname, @Diagnosis nvarchar(1000), @IncidentId int OUTPUT
AS
SET NOCOUNT ON;
SELECT @IncidentId = IncidentId FROM dbo.Incident
WHERE Kind = @Kind AND SubscriberName = @SubscriberName AND ResolvedAt IS NULL;
IF @IncidentId IS NULL
BEGIN
    INSERT dbo.Incident (Kind, SubscriberName, Diagnosis) VALUES (@Kind, @SubscriberName, @Diagnosis);
    SET @IncidentId = SCOPE_IDENTITY();
    -- Written to the SQL Server error log; wire an Agent alert or Database Mail to this text.
    RAISERROR(N'ReplMon incident %d: %s on %s. %s', 10, 1, @IncidentId, @Kind, @SubscriberName, @Diagnosis) WITH LOG;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_ResolveIncident @Kind varchar(20), @SubscriberName sysname
AS
SET NOCOUNT ON;
UPDATE dbo.Incident SET ResolvedAt = GETDATE()
WHERE Kind = @Kind AND SubscriberName = @SubscriberName AND ResolvedAt IS NULL;
IF @@ROWCOUNT > 0
    RAISERROR(N'ReplMon: %s on %s resolved.', 10, 1, @Kind, @SubscriberName) WITH LOG;
GO
/* ------------------------------------------------------------------ tracer tokens */
CREATE OR ALTER PROCEDURE dbo.usp_PostTracerToken @TracerId int = NULL OUTPUT
AS
SET NOCOUNT ON;
DECLARE @db sysname = dbo.fn_Setting(N'PublisherDb'), @pub sysname = dbo.fn_Setting(N'Publication');
DECLARE @proc nvarchar(300) = QUOTENAME(@db) + N'.sys.sp_posttracertoken';
EXEC @proc @publication = @pub, @tracer_token_id = @TracerId OUTPUT;
GO
CREATE OR ALTER PROCEDURE dbo.usp_HarvestTracerLatency
AS
SET NOCOUNT ON;
INSERT dbo.TracerLatency (TracerId, SubscriberName, PublisherCommit, DistributorCommit, SubscriberCommit,
                          DistLatencyMs, SubLatencyMs)
SELECT t.tracer_id, v.SubscriberName, t.publisher_commit, t.distributor_commit, h.subscriber_commit,
       DATEDIFF(MILLISECOND, t.publisher_commit, t.distributor_commit),
       DATEDIFF(MILLISECOND, t.distributor_commit, h.subscriber_commit)
FROM distribution.dbo.MStracer_tokens t
JOIN distribution.dbo.MStracer_history h ON h.parent_tracer_id = t.tracer_id
JOIN dbo.vSubscriberAgent v ON v.AgentId = h.agent_id
WHERE h.subscriber_commit IS NOT NULL
  AND t.distributor_commit IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.TracerLatency x
                  WHERE x.TracerId = t.tracer_id AND x.SubscriberName = v.SubscriberName);
GO
/* Seconds the oldest unacknowledged token has been waiting at this subscriber (NULL = none) */
CREATE OR ALTER FUNCTION dbo.fn_PendingTokenAgeSec (@AgentId int, @Since datetime2(3))
RETURNS int
AS
BEGIN
    RETURN (
        SELECT DATEDIFF(SECOND, MIN(t.publisher_commit), GETDATE())
        FROM distribution.dbo.MStracer_tokens t
        JOIN distribution.dbo.MSpublications p ON p.publication_id = t.publication_id
        WHERE p.publication = dbo.fn_Setting(N'Publication')
          AND p.publisher_db = dbo.fn_Setting(N'PublisherDb')
          AND t.publisher_commit > @Since
          AND t.publisher_commit > DATEADD(MINUTE, -30, GETDATE())
          -- Tokens are delivered in order, so a token older than one that HAS arrived was
          -- discarded (e.g. by a reinitialization), not delayed. Only count newer ones.
          AND t.publisher_commit > ISNULL((
                SELECT MAX(t2.publisher_commit)
                FROM distribution.dbo.MStracer_tokens t2
                JOIN distribution.dbo.MStracer_history h2 ON h2.parent_tracer_id = t2.tracer_id
                WHERE h2.agent_id = @AgentId AND h2.subscriber_commit IS NOT NULL), '19000101')
          AND NOT EXISTS (SELECT 1 FROM distribution.dbo.MStracer_history h
                          WHERE h.parent_tracer_id = t.tracer_id AND h.agent_id = @AgentId
                            AND h.subscriber_commit IS NOT NULL));
END;
GO
/* Posts a token and waits until it has been committed at the subscriber.
   Everything committed at the publisher before the token is then applied there:
   that makes the token a consistency barrier for drift checks. */
CREATE OR ALTER PROCEDURE dbo.usp_WaitForBarrier @SubscriberName sysname, @Arrived bit OUTPUT
AS
SET NOCOUNT ON;
DECLARE @TracerId int, @AgentId int, @deadline datetime2(3) =
        DATEADD(SECOND, CAST(dbo.fn_Setting(N'BarrierTimeoutSec') AS int), GETDATE());
SELECT @AgentId = AgentId FROM dbo.vSubscriberAgent WHERE SubscriberName = @SubscriberName;
EXEC dbo.usp_PostTracerToken @TracerId = @TracerId OUTPUT;
SET @Arrived = 0;
WHILE GETDATE() < @deadline
BEGIN
    IF EXISTS (SELECT 1 FROM distribution.dbo.MStracer_history
               WHERE parent_tracer_id = @TracerId AND agent_id = @AgentId AND subscriber_commit IS NOT NULL)
    BEGIN SET @Arrived = 1; BREAK; END
    WAITFOR DELAY '00:00:02';
END
GO
/* ------------------------------------------------------------------ article metadata */
/* Fills #Articles (created by the caller) with each published table, its key expression,
   and the column lists the reconcile needs. Runs inside the publisher database. */
CREATE OR ALTER PROCEDURE dbo.usp_LoadArticles
AS
SET NOCOUNT ON;
DECLARE @db sysname = dbo.fn_Setting(N'PublisherDb'), @pub sysname = dbo.fn_Setting(N'Publication');
DECLARE @exec nvarchar(300) = QUOTENAME(@db) + N'.sys.sp_executesql';
DECLARE @sql nvarchar(max) = N'
SELECT OBJECT_SCHEMA_NAME(a.objid), OBJECT_NAME(a.objid),
       (SELECT STRING_AGG(CONVERT(nvarchar(max), N''CONVERT(nvarchar(100),'' + QUOTENAME(c.name) + N'')''), N''+N''''|''''+'')
               WITHIN GROUP (ORDER BY ic.key_ordinal)
        FROM sys.indexes i
        JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE i.object_id = a.objid AND i.is_primary_key = 1),
       (SELECT STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(c.name)), N'','') WITHIN GROUP (ORDER BY c.column_id)
        FROM sys.columns c WHERE c.object_id = a.objid AND c.is_computed = 0),
       (SELECT STRING_AGG(CONVERT(nvarchar(max), N''s.'' + QUOTENAME(c.name) + N'' = p.'' + QUOTENAME(c.name)), N'' AND '')
        FROM sys.indexes i
        JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE i.object_id = a.objid AND i.is_primary_key = 1),
       (SELECT STRING_AGG(CONVERT(nvarchar(max), N''s.'' + QUOTENAME(c.name) + N'' = p.'' + QUOTENAME(c.name)), N'', '')
        FROM sys.columns c
        WHERE c.object_id = a.objid AND c.is_computed = 0
          AND NOT EXISTS (SELECT 1 FROM sys.indexes i
                          JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                          WHERE i.object_id = a.objid AND i.is_primary_key = 1 AND ic.column_id = c.column_id))
FROM dbo.sysarticles a
JOIN dbo.syspublications p ON p.pubid = a.pubid
WHERE p.name = @pub;';
INSERT #Articles (SchemaName, TableName, KeyExpr, ColList, JoinPred, SetList)
EXEC @exec @sql, N'@pub sysname', @pub = @pub;
GO
/* ------------------------------------------------------------------ repair */
/* Row-level repair: make ONE subscriber row match the publisher.
     @Mode 'sync'   : delete the subscriber row, then copy the publisher row (if it exists)
           'delete' : delete the subscriber row only (the agent will re-insert it)
     @KeyValues     : the key column values in primary-key order, separated by '|'
   Row-level on purpose. A whole-table reconcile while the agent has a backlog copies rows
   that are still queued, and the agent then fails with duplicate keys when it replays them. */
CREATE OR ALTER PROCEDURE dbo.usp_RepairRow
    @SubscriberName sysname, @SchemaName sysname, @TableName sysname,
    @KeyValues nvarchar(400), @Mode varchar(10) = 'sync', @RowsFixed int = 0 OUTPUT,
    -- evidence for dbo.RepairLog (all optional)
    @IncidentId int = NULL, @ErrorCode sysname = NULL, @ErrorText nvarchar(1000) = NULL,
    @XactSeqno varbinary(16) = NULL, @CommandId int = NULL
AS
SET NOCOUNT ON;
DECLARE @db sysname = dbo.fn_Setting(N'PublisherDb'), @ls sysname, @subdb sysname, @del int = 0, @ins int = 0;
SELECT @ls = LinkedServer, @subdb = SubscriberDb FROM dbo.Subscriber WHERE SubscriberName = @SubscriberName;
DECLARE @execPub nvarchar(300) = QUOTENAME(@db) + N'.sys.sp_executesql';
DECLARE @obj nvarchar(300) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);
DECLARE @keycols nvarchar(max), @cols nvarchar(max), @pred nvarchar(max), @q nvarchar(max);

SET @q = N'
SELECT @k = STRING_AGG(CONVERT(nvarchar(max), c.name), N''|'') WITHIN GROUP (ORDER BY ic.key_ordinal)
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(@obj) AND i.is_primary_key = 1;
SELECT @c = STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(name)), N'','') WITHIN GROUP (ORDER BY column_id)
FROM sys.columns WHERE object_id = OBJECT_ID(@obj) AND is_computed = 0;';
EXEC @execPub @q, N'@obj nvarchar(300), @k nvarchar(max) OUTPUT, @c nvarchar(max) OUTPUT',
     @obj = @obj, @k = @keycols OUTPUT, @c = @cols OUTPUT;
IF @keycols IS NULL THROW 50002, N'Table has no primary key at the publisher.', 1;
IF (SELECT COUNT(*) FROM STRING_SPLIT(@keycols, N'|', 1)) <> (SELECT COUNT(*) FROM STRING_SPLIT(@KeyValues, N'|', 1))
    THROW 50003, N'Number of key values does not match the primary key.', 1;

-- key values become N'...' literals (quotes doubled), never raw SQL
SELECT @pred = STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(k.value) + N' = N'''
               + REPLACE(TRIM(v.value), N'''', N'''''') + N''''), N' AND ')
FROM STRING_SPLIT(@keycols, N'|', 1) k
JOIN STRING_SPLIT(@KeyValues, N'|', 1) v ON v.ordinal = k.ordinal;

DECLARE @rt nvarchar(1000) = QUOTENAME(@ls) + N'.' + QUOTENAME(@subdb) + N'.' + @obj;
DECLARE @lt nvarchar(1000) = QUOTENAME(@db) + N'.' + @obj;

-- evidence before the repair
DECLARE @before nvarchar(max), @pubrow nvarchar(max), @after nvarchar(max), @cmd nvarchar(max);
SET @q = N'SET @j = (SELECT * FROM ' + @rt + N' WHERE ' + @pred + N' FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);';
EXEC sys.sp_executesql @q, N'@j nvarchar(max) OUTPUT', @j = @before OUTPUT;
SET @q = N'SET @j = (SELECT * FROM ' + @lt + N' WHERE ' + @pred + N' FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);';
EXEC sys.sp_executesql @q, N'@j nvarchar(max) OUTPUT', @j = @pubrow OUTPUT;

-- the repair itself
SET @q = N'DELETE FROM ' + @rt + N' WHERE ' + @pred + N'; SET @n = @@ROWCOUNT;';
EXEC sys.sp_executesql @q, N'@n int OUTPUT', @n = @del OUTPUT;
IF @Mode = 'sync'
BEGIN
    SET @q = N'INSERT INTO ' + @rt + N' (' + @cols + N') SELECT ' + @cols + N' FROM ' + @lt
           + N' WHERE ' + @pred + N'; SET @n = @@ROWCOUNT;';
    EXEC sys.sp_executesql @q, N'@n int OUTPUT', @n = @ins OUTPUT;
END
SET @RowsFixed = CASE WHEN @ins > 0 THEN @ins ELSE @del END;

-- evidence after the repair (best effort: never fail the repair because of logging)
BEGIN TRY
    SET @q = N'SET @j = (SELECT * FROM ' + @rt + N' WHERE ' + @pred + N' FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);';
    EXEC sys.sp_executesql @q, N'@j nvarchar(max) OUTPUT', @j = @after OUTPUT;

    IF @XactSeqno IS NOT NULL
    BEGIN
        BEGIN TRY
            -- decode the failed replicated command (the agent's real statement) from MSrepl_commands
            CREATE TABLE #cmd (xact_seqno varbinary(16), originator_srvname sysname NULL, originator_db sysname NULL,
                               article_id int NULL, type int NULL, partial_command bit NULL, hashkey int NULL,
                               originator_publication_id int NULL, originator_db_version int NULL,
                               originator_lsn varbinary(16) NULL, command nvarchar(1024) NULL, command_id int NULL);
            DECLARE @seq nvarchar(64) = CONVERT(nvarchar(64), @XactSeqno, 1);   -- full length: xact_seqno is 14 bytes here, not 10
            INSERT #cmd EXEC distribution.sys.sp_browsereplcmds @xact_seqno_start = @seq, @xact_seqno_end = @seq;
            SELECT @cmd = STRING_AGG(CONVERT(nvarchar(max), command), N'') WITHIN GROUP (ORDER BY command_id)
            FROM #cmd WHERE @CommandId IS NULL OR command_id = @CommandId;
        END TRY
        BEGIN CATCH
            SET @cmd = CONCAT(N'(not decoded: ', ERROR_MESSAGE(), N')');
        END CATCH
    END

    INSERT dbo.RepairLog (IncidentId, SubscriberName, TableName, KeyValues, Mode, ErrorCode, ErrorText,
                          FailedCommand, SubscriberBefore, PublisherRow, SubscriberAfter)
    VALUES (@IncidentId, @SubscriberName, @obj, @KeyValues, @Mode, @ErrorCode, @ErrorText,
            @cmd, @before, @pubrow, @after);
END TRY
BEGIN CATCH
    DECLARE @m nvarchar(2048) = ERROR_MESSAGE();
    RAISERROR(N'ReplMon: repair succeeded but RepairLog failed: %s', 10, 1, @m) WITH LOG;
END CATCH
GO
/* Unique constraint / unique index conflicts (2627 UNIQUE KEY, 2601): the row in the way has a
   DIFFERENT primary key from the row being applied. The publisher is the judge, row by row:
     blocking row not at the publisher          -> stray: delete it at the subscriber
     at the publisher with a different value    -> stale copy: resync it from the publisher
     at the publisher with the SAME value       -> the subscriber is right and the incoming change
                                                   conflicts (e.g. a key swap in flight): no repair
   Limits: the duplicate value is read from the error message, so values containing ", " in a
   multi-column key, or dates in another format, are diagnosed rather than repaired. */
CREATE OR ALTER PROCEDURE dbo.usp_RepairUniqueConflict
    @SubscriberName sysname, @Object nvarchar(300), @IndexName sysname, @DupValue nvarchar(1000),
    @RowsFixed int = 0 OUTPUT, @Detail nvarchar(500) = NULL OUTPUT,
    @IncidentId int = NULL, @ErrorCode sysname = NULL, @ErrorText nvarchar(1000) = NULL,
    @XactSeqno varbinary(16) = NULL, @CommandId int = NULL
AS
SET NOCOUNT ON;
DECLARE @db sysname = dbo.fn_Setting(N'PublisherDb'), @ls sysname, @subdb sysname;
SELECT @ls = LinkedServer, @subdb = SubscriberDb FROM dbo.Subscriber WHERE SubscriberName = @SubscriberName;
DECLARE @execPub nvarchar(300) = QUOTENAME(@db) + N'.sys.sp_executesql';
DECLARE @s sysname = PARSENAME(@Object, 2), @t sysname = PARSENAME(@Object, 1);
DECLARE @obj nvarchar(300) = QUOTENAME(@s) + N'.' + QUOTENAME(@t);
DECLARE @ucols nvarchar(max), @pkexpr nvarchar(max), @pkcols nvarchar(max), @q nvarchar(max);
SET @RowsFixed = 0;

-- the unique index's key columns, and the primary key, from the publisher
SET @q = N'
SELECT @u = STRING_AGG(CONVERT(nvarchar(max), c.name), N''|'') WITHIN GROUP (ORDER BY ic.key_ordinal)
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(@obj) AND i.name = @ix AND i.is_unique = 1;
SELECT @pn = STRING_AGG(CONVERT(nvarchar(max), c.name), N''|'') WITHIN GROUP (ORDER BY ic.key_ordinal),
       @k  = STRING_AGG(CONVERT(nvarchar(max), N''CONVERT(nvarchar(100),'' + QUOTENAME(c.name) + N'')''), N''+N''''|''''+'')
             WITHIN GROUP (ORDER BY ic.key_ordinal)
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(@obj) AND i.is_primary_key = 1;';
EXEC @execPub @q, N'@obj nvarchar(300), @ix sysname, @u nvarchar(max) OUTPUT, @pn nvarchar(max) OUTPUT, @k nvarchar(max) OUTPUT',
     @obj = @obj, @ix = @IndexName, @u = @ucols OUTPUT, @pn = @pkcols OUTPUT, @k = @pkexpr OUTPUT;
IF @ucols IS NULL OR @pkexpr IS NULL
BEGIN
    SET @Detail = CONCAT(N'Not auto-repaired: unique index ', @IndexName, N' or the primary key of ', @obj, N' not found at the publisher.');
    RETURN;
END

-- the duplicate value(s) from the error message, in index-key order
DECLARE @nCols int = (SELECT COUNT(*) FROM STRING_SPLIT(@ucols, N'|', 1));
DECLARE @vals TABLE (ordinal int, v nvarchar(1000));
IF @nCols = 1 INSERT @vals VALUES (1, @DupValue);
ELSE INSERT @vals SELECT ordinal, value FROM STRING_SPLIT(REPLACE(@DupValue, N', ', NCHAR(1)), NCHAR(1), 1);
IF (SELECT COUNT(*) FROM @vals) <> @nCols
BEGIN
    SET @Detail = CONCAT(N'Not auto-repaired: could not match value (', @DupValue, N') to the columns of ', @IndexName, N'.');
    RETURN;
END

-- predicate on the unique columns; values become N'...' literals, never raw SQL
DECLARE @upred nvarchar(max);
SELECT @upred = STRING_AGG(CONVERT(nvarchar(max),
         CASE WHEN v.v = N'<NULL>' THEN QUOTENAME(c.value) + N' IS NULL'
              ELSE N'CONVERT(nvarchar(1000),' + QUOTENAME(c.value) + N') = N''' + REPLACE(v.v, N'''', N'''''') + N'''' END),
         N' AND ')
FROM STRING_SPLIT(@ucols, N'|', 1) c JOIN @vals v ON v.ordinal = c.ordinal;

DECLARE @rt nvarchar(1000) = QUOTENAME(@ls) + N'.' + QUOTENAME(@subdb) + N'.' + @obj;
DECLARE @lt nvarchar(1000) = QUOTENAME(@db) + N'.' + @obj;

-- 1. which subscriber rows hold the duplicate value?
CREATE TABLE #blk (k nvarchar(400) PRIMARY KEY, verdict varchar(10) NULL);
SET @q = N'SELECT ' + @pkexpr + N' FROM ' + @rt + N' WHERE ' + @upred + N';';
INSERT #blk (k) EXEC sys.sp_executesql @q;
IF NOT EXISTS (SELECT 1 FROM #blk)
BEGIN
    SET @Detail = CONCAT(N'Not auto-repaired: no subscriber row holds (', @DupValue, N') in ', @IndexName, N'; needs a human decision.');
    RETURN;
END

-- 2. judge each blocking row against the publisher
DECLARE @k nvarchar(400), @kpred nvarchar(max), @exists int, @same int;
DECLARE b CURSOR LOCAL FAST_FORWARD FOR SELECT k FROM #blk;
OPEN b; FETCH NEXT FROM b INTO @k;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @kpred = STRING_AGG(CONVERT(nvarchar(max), QUOTENAME(c.value) + N' = N'''
                    + REPLACE(TRIM(v.value), N'''', N'''''') + N''''), N' AND ')
    FROM STRING_SPLIT(@pkcols, N'|', 1) c JOIN STRING_SPLIT(@k, N'|', 1) v ON v.ordinal = c.ordinal;
    SET @q = N'SELECT @e = COUNT(*), @m = ISNULL(SUM(CASE WHEN ' + @upred + N' THEN 1 ELSE 0 END), 0) FROM ' + @lt + N' WHERE ' + @kpred + N';';
    EXEC sys.sp_executesql @q, N'@e int OUTPUT, @m int OUTPUT', @e = @exists OUTPUT, @m = @same OUTPUT;
    UPDATE #blk SET verdict = CASE WHEN @exists = 0 THEN 'delete' WHEN @same > 0 THEN 'match' ELSE 'sync' END WHERE k = @k;
    FETCH NEXT FROM b INTO @k;
END
CLOSE b; DEALLOCATE b;

IF EXISTS (SELECT 1 FROM #blk WHERE verdict = 'match')
BEGIN
    SET @Detail = CONCAT(N'Not auto-repaired: the subscriber row holding (', @DupValue, N') in ', @IndexName,
                         N' matches the publisher, so the incoming change conflicts with current data (e.g. a key swap in flight); needs a human decision.');
    RETURN;
END

-- 3. repair: every blocking row is stray or stale, so the publisher decides
DECLARE @mode varchar(10), @n int, @del int = 0, @syn int = 0;
DECLARE r CURSOR LOCAL FAST_FORWARD FOR SELECT k, verdict FROM #blk;
OPEN r; FETCH NEXT FROM r INTO @k, @mode;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_RepairRow @SubscriberName, @s, @t, @k, @mode, @RowsFixed = @n OUTPUT,
         @IncidentId = @IncidentId, @ErrorCode = @ErrorCode, @ErrorText = @ErrorText,
         @XactSeqno = @XactSeqno, @CommandId = @CommandId;
    SET @RowsFixed += @n;
    IF @mode = 'delete' SET @del += 1; ELSE SET @syn += 1;
    FETCH NEXT FROM r INTO @k, @mode;
END
CLOSE r; DEALLOCATE r;
SET @Detail = CONCAT(N'Cleared ', @IndexName, N' conflict on ', @obj, N' value (', @DupValue, N'): removed ', @del,
                     N' stray row(s), resynced ', @syn, N' stale row(s) from the publisher');
GO
/* Repairs the single row named in a Distribution Agent error:
     20598 on an UPDATE : the row is missing at the subscriber -> restore it from the publisher,
                          then the agent re-applies the UPDATE
     2627 on a PRIMARY KEY : a stale row is in the way of an INSERT -> remove it,
                          then the agent re-applies the INSERT
   Anything else (e.g. 20598 on a DELETE, 2601 on a unique index) is diagnosed, not repaired. */
CREATE OR ALTER PROCEDURE dbo.usp_RepairConflict
    @SubscriberName sysname, @ErrCode sysname, @ErrText nvarchar(1000),
    @RowsFixed int = 0 OUTPUT, @Detail nvarchar(500) = NULL OUTPUT,
    @IncidentId int = NULL, @XactSeqno varbinary(16) = NULL, @CommandId int = NULL
AS
SET NOCOUNT ON;
DECLARE @obj nvarchar(300), @keys nvarchar(400), @i int, @j int, @mode varchar(10);
SET @RowsFixed = 0;

IF @ErrCode = N'20598' AND @ErrText LIKE N'%replicated UPDATE command%Primary Key(s): %'
BEGIN
    -- ...applying the replicated UPDATE command for Table '[dbo].[Customer]' with Primary Key(s): [CustomerID] = 338
    SET @i = CHARINDEX(N'Table ''', @ErrText) + 7;
    SET @j = CHARINDEX(N'''', @ErrText, @i);
    SET @obj = SUBSTRING(@ErrText, @i, @j - @i);
    SET @keys = SUBSTRING(@ErrText, CHARINDEX(N'Primary Key(s): ', @ErrText) + 16, 400);
    SELECT @keys = STRING_AGG(TRIM(N' .' FROM SUBSTRING(value, CHARINDEX(N'=', value) + 1, 400)), N'|')
                   WITHIN GROUP (ORDER BY ordinal)
    FROM STRING_SPLIT(@keys, N',', 1);
    SET @mode = 'sync';
END
ELSE IF @ErrCode = N'2627' AND @ErrText LIKE N'Violation of PRIMARY KEY constraint%duplicate key value is (%'
BEGIN
    -- Violation of PRIMARY KEY constraint 'PK_Customer'. Cannot insert duplicate key in object 'dbo.Customer'. The duplicate key value is (415).
    SET @i = CHARINDEX(N'object ''', @ErrText) + 8;
    SET @j = CHARINDEX(N'''', @ErrText, @i);
    SET @obj = SUBSTRING(@ErrText, @i, @j - @i);
    SET @i = CHARINDEX(N'value is (', @ErrText) + 10;
    SET @j = CHARINDEX(N')', @ErrText, @i);
    SET @keys = REPLACE(SUBSTRING(@ErrText, @i, @j - @i), N', ', N'|');
    SET @mode = 'delete';
END
ELSE IF (@ErrCode = N'2627' AND @ErrText LIKE N'Violation of UNIQUE KEY constraint%duplicate key value is (%')
     OR (@ErrCode = N'2601' AND @ErrText LIKE N'Cannot insert duplicate key row in object%with unique index%duplicate key value is (%')
BEGIN
    -- 2627: Violation of UNIQUE KEY constraint 'UQ_Product_Sku'. Cannot insert duplicate key in object 'dbo.Product'. The duplicate key value is (SKU-DEMO1).
    -- 2601: Cannot insert duplicate key row in object 'dbo.Customer' with unique index 'UX_Customer_Email'. The duplicate key value is (x@example.com).
    DECLARE @ix sysname, @dup nvarchar(1000);
    SET @i = CHARINDEX(N'object ''', @ErrText) + 8;
    SET @j = CHARINDEX(N'''', @ErrText, @i);
    SET @obj = SUBSTRING(@ErrText, @i, @j - @i);
    SET @i = CASE WHEN @ErrCode = N'2627' THEN CHARINDEX(N'constraint ''', @ErrText) + 12
                  ELSE CHARINDEX(N'unique index ''', @ErrText) + 14 END;
    SET @j = CHARINDEX(N'''', @ErrText, @i);
    SET @ix = SUBSTRING(@ErrText, @i, @j - @i);
    SET @i = CHARINDEX(N'value is (', @ErrText) + 10;
    SET @j = LEN(@ErrText) - CHARINDEX(N')', REVERSE(@ErrText)) + 1;     -- the last ')'
    SET @dup = SUBSTRING(@ErrText, @i, @j - @i);
    EXEC dbo.usp_RepairUniqueConflict @SubscriberName, @obj, @ix, @dup,
         @RowsFixed = @RowsFixed OUTPUT, @Detail = @Detail OUTPUT,
         @IncidentId = @IncidentId, @ErrorCode = @ErrCode, @ErrorText = @ErrText,
         @XactSeqno = @XactSeqno, @CommandId = @CommandId;
    RETURN;
END
ELSE
BEGIN
    SET @Detail = CONCAT(N'Not auto-repaired (error ', @ErrCode, N'): needs a human decision.');
    RETURN;
END

DECLARE @s sysname = PARSENAME(@obj, 2), @t sysname = PARSENAME(@obj, 1);
EXEC dbo.usp_RepairRow @SubscriberName, @s, @t, @keys, @mode, @RowsFixed = @RowsFixed OUTPUT,
     @IncidentId = @IncidentId, @ErrorCode = @ErrCode, @ErrorText = @ErrText,
     @XactSeqno = @XactSeqno, @CommandId = @CommandId;
SET @Detail = CASE @mode
    WHEN 'sync' THEN CONCAT(N'Restored ', @obj, N' key (', @keys, N') from the publisher')
    ELSE CONCAT(N'Removed stale ', @obj, N' key (', @keys, N') so the agent can re-insert it') END;
GO
/* Full key-based reconcile of one subscriber table from the publisher (manual tool):
   delete extra rows, insert missing rows, update changed rows. Like tablediff, but in-engine.
   Only run it with the Distribution Agent stopped and its backlog drained: rows still queued
   would be copied early and the agent would fail with duplicate keys on replay. */
CREATE OR ALTER PROCEDURE dbo.usp_ReconcileTable
    @SubscriberName sysname, @SchemaName sysname, @TableName sysname, @RowsFixed int = 0 OUTPUT
AS
SET NOCOUNT ON;
DECLARE @db sysname = dbo.fn_Setting(N'PublisherDb'), @ls sysname, @subdb sysname, @n int;
SELECT @ls = LinkedServer, @subdb = SubscriberDb FROM dbo.Subscriber WHERE SubscriberName = @SubscriberName;

IF OBJECT_ID(N'tempdb..#Articles') IS NULL   -- reuse the caller's list when nested
BEGIN
    CREATE TABLE #Articles (SchemaName sysname, TableName sysname, KeyExpr nvarchar(max),
                            ColList nvarchar(max), JoinPred nvarchar(max), SetList nvarchar(max));
    EXEC dbo.usp_LoadArticles;
END

DECLARE @cols nvarchar(max), @join nvarchar(max), @set nvarchar(max);
SELECT @cols = ColList, @join = JoinPred, @set = SetList
FROM #Articles WHERE SchemaName = @SchemaName AND TableName = @TableName;
IF @join IS NULL THROW 50001, N'Table is not a published article with a primary key.', 1;

DECLARE @pcols nvarchar(max) = N'p.' + REPLACE(@cols, N',', N',p.');
DECLARE @scols nvarchar(max) = N's.' + REPLACE(@cols, N',', N',s.');
DECLARE @rt nvarchar(1000) = QUOTENAME(@ls) + N'.' + QUOTENAME(@subdb) + N'.' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);
DECLARE @lt nvarchar(1000) = QUOTENAME(@db) + N'.' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);
DECLARE @sql nvarchar(max);

SET @RowsFixed = 0;
SET @sql = N'DELETE s FROM ' + @rt + N' AS s WHERE NOT EXISTS (SELECT 1 FROM ' + @lt + N' AS p WHERE ' + @join + N'); SET @n = @@ROWCOUNT;';
EXEC sys.sp_executesql @sql, N'@n int OUTPUT', @n = @n OUTPUT;  SET @RowsFixed += @n;

SET @sql = N'INSERT INTO ' + @rt + N' (' + @cols + N') SELECT ' + @pcols + N' FROM ' + @lt
         + N' AS p WHERE NOT EXISTS (SELECT 1 FROM ' + @rt + N' AS s WHERE ' + @join + N'); SET @n = @@ROWCOUNT;';
EXEC sys.sp_executesql @sql, N'@n int OUTPUT', @n = @n OUTPUT;  SET @RowsFixed += @n;

IF @set IS NOT NULL
BEGIN
    SET @sql = N'UPDATE s SET ' + @set + N' FROM ' + @rt + N' AS s JOIN ' + @lt + N' AS p ON ' + @join
             + N' WHERE EXISTS (SELECT ' + @scols + N' EXCEPT SELECT ' + @pcols + N'); SET @n = @@ROWCOUNT;';
    EXEC sys.sp_executesql @sql, N'@n int OUTPUT', @n = @n OUTPUT;  SET @RowsFixed += @n;
END
GO
CREATE OR ALTER PROCEDURE dbo.usp_ReconcileSubscriber
    @SubscriberName sysname, @OnlyTables nvarchar(max) = NULL, @RowsFixed int = 0 OUTPUT
AS
SET NOCOUNT ON;
CREATE TABLE #Articles (SchemaName sysname, TableName sysname, KeyExpr nvarchar(max),
                        ColList nvarchar(max), JoinPred nvarchar(max), SetList nvarchar(max));
EXEC dbo.usp_LoadArticles;
DECLARE @s sysname, @t sysname, @n int;
SET @RowsFixed = 0;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT SchemaName, TableName FROM #Articles
    WHERE @OnlyTables IS NULL
       OR QUOTENAME(SchemaName) + N'.' + QUOTENAME(TableName)
          IN (SELECT LTRIM(value) FROM STRING_SPLIT(@OnlyTables, N','));
OPEN c; FETCH NEXT FROM c INTO @s, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.usp_ReconcileTable @SubscriberName, @s, @t, @RowsFixed = @n OUTPUT;
    SET @RowsFixed += @n;
    FETCH NEXT FROM c INTO @s, @t;
END
CLOSE c; DEALLOCATE c;
GO
/* ------------------------------------------------------------------ drift detection */
/* Pass 1: rowcount + CHECKSUM_AGG per table (cheap). Tables that differ get a key-level diff.
   Then a tracer-token barrier, then pass 2. A key is drift only if the publisher row did not
   change between passes AND the subscriber still differs after the barrier arrived, so rows
   that were merely in flight never raise a false alarm. */
CREATE OR ALTER PROCEDURE dbo.usp_CheckDrift
    @SubscriberName sysname, @DriftTables nvarchar(max) = NULL OUTPUT, @DriftKeys int = 0 OUTPUT,
    @Outcome varchar(20) = NULL OUTPUT
AS
SET NOCOUNT ON;
DECLARE @db sysname = dbo.fn_Setting(N'PublisherDb'), @ls sysname, @subdb sysname;
SELECT @ls = LinkedServer, @subdb = SubscriberDb FROM dbo.Subscriber WHERE SubscriberName = @SubscriberName;
DECLARE @execPub nvarchar(300) = QUOTENAME(@db) + N'.sys.sp_executesql';
DECLARE @execRemote nvarchar(400) = N'EXEC (@q) AT ' + QUOTENAME(@ls) + N';';

CREATE TABLE #Articles (SchemaName sysname, TableName sysname, KeyExpr nvarchar(max),
                        ColList nvarchar(max), JoinPred nvarchar(max), SetList nvarchar(max));
EXEC dbo.usp_LoadArticles;

CREATE TABLE #agg (c bigint, h int);
CREATE TABLE #suspect (SchemaName sysname, TableName sysname, KeyExpr nvarchar(max), CheckId bigint);
CREATE TABLE #p1 (k nvarchar(400) PRIMARY KEY, h int);  CREATE TABLE #s1 (k nvarchar(400) PRIMARY KEY, h int);
CREATE TABLE #p2 (k nvarchar(400) PRIMARY KEY, h int);  CREATE TABLE #s2 (k nvarchar(400) PRIMARY KEY, h int);
CREATE TABLE #k1 (SchemaName sysname, TableName sysname, k nvarchar(400), ph int, sh int);

DECLARE @s sysname, @t sysname, @key nvarchar(max), @q nvarchar(max), @tbl nvarchar(300),
        @pc bigint, @ph int, @sc bigint, @sh int, @CheckId bigint;

/* Pass 1a: aggregate compare */
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT SchemaName, TableName, KeyExpr FROM #Articles;
OPEN c; FETCH NEXT FROM c INTO @s, @t, @key;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @tbl = QUOTENAME(@s) + N'.' + QUOTENAME(@t);
    TRUNCATE TABLE #agg;
    SET @q = N'SELECT COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM ' + @tbl + N';';
    INSERT #agg EXEC @execPub @q;
    SELECT @pc = c, @ph = h FROM #agg;  TRUNCATE TABLE #agg;
    SET @q = N'SELECT COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM ' + QUOTENAME(@subdb) + N'.' + @tbl + N';';
    INSERT #agg EXEC sys.sp_executesql @execRemote, N'@q nvarchar(max)', @q = @q;
    SELECT @sc = c, @sh = h FROM #agg;

    INSERT dbo.DriftCheck (SubscriberName, TableName, PubRows, SubRows, PubChecksum, SubChecksum, Outcome)
    VALUES (@SubscriberName, @tbl, @pc, @sc, @ph, @sh,
            CASE WHEN @pc = @sc AND @ph IS NOT DISTINCT FROM @sh THEN 'Clean' ELSE 'Suspect' END);
    SET @CheckId = SCOPE_IDENTITY();
    IF NOT (@pc = @sc AND @ph IS NOT DISTINCT FROM @sh)
        INSERT #suspect VALUES (@s, @t, @key, @CheckId);
    FETCH NEXT FROM c INTO @s, @t, @key;
END
CLOSE c; DEALLOCATE c;

SET @DriftKeys = 0; SET @DriftTables = NULL; SET @Outcome = 'Clean';
IF NOT EXISTS (SELECT 1 FROM #suspect) RETURN;

/* Pass 1b: key-level diff on suspect tables */
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT SchemaName, TableName, KeyExpr FROM #suspect;
OPEN c; FETCH NEXT FROM c INTO @s, @t, @key;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @tbl = QUOTENAME(@s) + N'.' + QUOTENAME(@t);
    TRUNCATE TABLE #p1; TRUNCATE TABLE #s1;
    SET @q = N'SELECT ' + @key + N', BINARY_CHECKSUM(*) FROM ' + @tbl + N';';
    INSERT #p1 EXEC @execPub @q;
    SET @q = N'SELECT ' + @key + N', BINARY_CHECKSUM(*) FROM ' + QUOTENAME(@subdb) + N'.' + @tbl + N';';
    INSERT #s1 EXEC sys.sp_executesql @execRemote, N'@q nvarchar(max)', @q = @q;
    INSERT #k1 (SchemaName, TableName, k, ph, sh)
    SELECT @s, @t, COALESCE(p.k, s.k), p.h, s.h
    FROM #p1 p FULL JOIN #s1 s ON s.k = p.k
    WHERE p.h IS DISTINCT FROM s.h;
    FETCH NEXT FROM c INTO @s, @t, @key;
END
CLOSE c; DEALLOCATE c;

IF NOT EXISTS (SELECT 1 FROM #k1)
BEGIN
    UPDATE d SET Outcome = 'InFlight' FROM dbo.DriftCheck d JOIN #suspect x ON x.CheckId = d.CheckId;
    RETURN;
END

/* Barrier: wait until a token posted now has reached this subscriber */
DECLARE @Arrived bit;
EXEC dbo.usp_WaitForBarrier @SubscriberName, @Arrived OUTPUT;
IF @Arrived = 0
BEGIN
    UPDATE d SET Outcome = 'Inconclusive' FROM dbo.DriftCheck d JOIN #suspect x ON x.CheckId = d.CheckId;
    SET @Outcome = 'Inconclusive';
    RETURN;   -- latency problem; the health check reports it
END

/* Pass 2 on the suspect keys */
DECLARE @drift TABLE (SchemaName sysname, TableName sysname, k nvarchar(400), kind varchar(10), ph int, sh int);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT SchemaName, TableName, KeyExpr FROM #suspect;
OPEN c; FETCH NEXT FROM c INTO @s, @t, @key;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @tbl = QUOTENAME(@s) + N'.' + QUOTENAME(@t);
    TRUNCATE TABLE #p2; TRUNCATE TABLE #s2;
    SET @q = N'SELECT ' + @key + N', BINARY_CHECKSUM(*) FROM ' + @tbl + N';';
    INSERT #p2 EXEC @execPub @q;
    SET @q = N'SELECT ' + @key + N', BINARY_CHECKSUM(*) FROM ' + QUOTENAME(@subdb) + N'.' + @tbl + N';';
    INSERT #s2 EXEC sys.sp_executesql @execRemote, N'@q nvarchar(max)', @q = @q;

    INSERT @drift (SchemaName, TableName, k, kind, ph, sh)
    SELECT @s, @t, k1.k,
           CASE WHEN p2.k IS NULL THEN 'Extra' WHEN s2.k IS NULL THEN 'Missing' ELSE 'Changed' END,
           p2.h, s2.h
    FROM #k1 k1
    LEFT JOIN #p2 p2 ON p2.k = k1.k
    LEFT JOIN #s2 s2 ON s2.k = k1.k
    WHERE k1.SchemaName = @s AND k1.TableName = @t
      AND k1.ph IS NOT DISTINCT FROM p2.h        -- publisher row stable across both passes
      AND p2.h IS DISTINCT FROM s2.h;            -- subscriber still differs after the barrier
    FETCH NEXT FROM c INTO @s, @t, @key;
END
CLOSE c; DEALLOCATE c;

INSERT dbo.DriftKey (CheckId, KeyValue, Kind, PubHash, SubHash)
SELECT x.CheckId, d.k, d.kind, d.ph, d.sh
FROM @drift d JOIN #suspect x ON x.SchemaName = d.SchemaName AND x.TableName = d.TableName;

UPDATE dc SET Outcome = CASE WHEN n.cnt > 0 THEN 'Drift' ELSE 'InFlight' END, DriftKeys = ISNULL(n.cnt, 0)
FROM dbo.DriftCheck dc
JOIN #suspect x ON x.CheckId = dc.CheckId
OUTER APPLY (SELECT COUNT(*) AS cnt FROM @drift d WHERE d.SchemaName = x.SchemaName AND d.TableName = x.TableName) n;

SELECT @DriftKeys = COUNT(*) FROM @drift;
SELECT @DriftTables = STRING_AGG(t, N',')
FROM (SELECT DISTINCT QUOTENAME(SchemaName) + N'.' + QUOTENAME(TableName) AS t FROM @drift) z;
SET @Outcome = CASE WHEN @DriftKeys > 0 THEN 'Drift' ELSE 'Clean' END;
GO
/* ------------------------------------------------------------------ orchestration */
CREATE OR ALTER PROCEDURE dbo.usp_HealthCheck
AS
SET NOCOUNT ON;
DECLARE @slo int = CAST(dbo.fn_Setting(N'LatencySloSec') AS int),
        @auto bit = CAST(dbo.fn_Setting(N'AutoRepair') AS bit);
DECLARE @sub sysname, @agent int, @job uniqueidentifier, @jobname sysname, @since datetime2(3),
        @running bit, @errTs binary(8), @errCode sysname, @errText nvarchar(1000), @okAfter bit,
        @pendingSec int, @lastMs int, @id int, @rows int, @diag nvarchar(1000), @lastAction datetime2(3),
        @lastDiag nvarchar(1000), @detail nvarchar(500), @errSeq varbinary(16), @errCmd int;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT SubscriberName, AgentId, JobId, JobName, RegisteredAt FROM dbo.vSubscriberAgent;
OPEN c; FETCH NEXT FROM c INTO @sub, @agent, @job, @jobname, @since;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @running = 0, @errTs = NULL, @errCode = NULL, @errText = NULL, @okAfter = 0, @lastMs = NULL,
           @errSeq = NULL, @errCmd = NULL;

    -- 1. Is the distribution agent job running?
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity ja
               WHERE ja.job_id = @job
                 AND ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
                 AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL)
        SET @running = 1;

    -- 2. Latest agent error in the last 5 minutes, and whether delivery recovered after it.
    --    MSdistribution_history.error_id points at the 14151 summary row ("agent ... failed");
    --    the root cause (20598, 2627, 2601) is written to MSrepl_errors under the NEXT id,
    --    so look at both ids, within a few seconds of the history row.
    SELECT TOP (1) @errTs = h.[timestamp], @errCode = e.error_code, @errText = LEFT(e.error_text, 1000),
           -- the failed command's transaction and position, from whichever row of the chain carries it
           @errSeq = (SELECT MAX(e2.xact_seqno) FROM distribution.dbo.MSrepl_errors e2
                      WHERE e2.id IN (h.error_id, h.error_id + 1) AND e2.xact_seqno IS NOT NULL
                        AND e2.xact_seqno <> 0x00000000000000000000),
           @errCmd = (SELECT MAX(e2.command_id) FROM distribution.dbo.MSrepl_errors e2
                      WHERE e2.id IN (h.error_id, h.error_id + 1))
    FROM distribution.dbo.MSdistribution_history h
    JOIN distribution.dbo.MSrepl_errors e
      ON e.id IN (h.error_id, h.error_id + 1)
     AND e.[time] BETWEEN DATEADD(SECOND, -5, h.[time]) AND DATEADD(SECOND, 5, h.[time])
    WHERE h.agent_id = @agent AND h.error_id <> 0 AND h.[time] > DATEADD(MINUTE, -5, GETDATE())
      AND e.error_code IN (N'20598', N'2627', N'2601')
    ORDER BY h.[timestamp] DESC;
    IF @errTs IS NOT NULL AND EXISTS (SELECT 1 FROM distribution.dbo.MSdistribution_history h
                                      WHERE h.agent_id = @agent AND h.[timestamp] > @errTs
                                        AND (h.runstatus IN (2, 4) OR (h.runstatus = 3 AND h.delivered_commands > 0)))
        SET @okAfter = 1;

    -- 3. Latency
    SET @pendingSec = dbo.fn_PendingTokenAgeSec(@agent, @since);
    SELECT TOP (1) @lastMs = TotalLatencyMs FROM dbo.TracerLatency
    WHERE SubscriberName = @sub AND PublisherCommit > DATEADD(MINUTE, -10, GETDATE())
    ORDER BY TracerId DESC;

    /* --- DataConflict --- */
    IF @errTs IS NOT NULL AND @okAfter = 0
    BEGIN
        SET @diag = CONCAT(N'Distribution agent failing with error ', @errCode, N': ', @errText);
        EXEC dbo.usp_OpenIncident 'DataConflict', @sub, @diag, @id OUTPUT;
        SELECT @lastAction = ActionAt, @lastDiag = Diagnosis FROM dbo.Incident WHERE IncidentId = @id;
        -- repair a new error at once; retry the same error at most every 90 s
        IF @auto = 1 AND (@lastAction IS NULL OR @lastAction < DATEADD(SECOND, -90, GETDATE()) OR @lastDiag <> @diag)
        BEGIN
            BEGIN TRY
                EXEC dbo.usp_RepairConflict @sub, @errCode, @errText, @RowsFixed = @rows OUTPUT, @Detail = @detail OUTPUT,
                     @IncidentId = @id, @XactSeqno = @errSeq, @CommandId = @errCmd;
                IF @detail NOT LIKE N'Not auto-repaired%'
                BEGIN
                    IF @running = 1 BEGIN EXEC msdb.dbo.sp_stop_job @job_id = @job; WAITFOR DELAY '00:00:05'; END
                    EXEC msdb.dbo.sp_start_job @job_id = @job;
                    SET @detail = CONCAT(@detail, N'; restarted ', @jobname);
                END
                UPDATE dbo.Incident SET ActionAt = GETDATE(), Diagnosis = @diag, Action = @detail
                WHERE IncidentId = @id;
            END TRY
            BEGIN CATCH
                UPDATE dbo.Incident SET ActionAt = GETDATE(), Action = CONCAT(N'Repair failed: ', ERROR_MESSAGE())
                WHERE IncidentId = @id;
            END CATCH
        END
    END
    ELSE EXEC dbo.usp_ResolveIncident 'DataConflict', @sub;

    /* --- AgentStopped --- */
    IF @running = 0 AND NOT (@errTs IS NOT NULL AND @okAfter = 0)
    BEGIN
        EXEC dbo.usp_OpenIncident 'AgentStopped', @sub, N'Distribution agent job is not running.', @id OUTPUT;
        IF @auto = 1
        BEGIN
            BEGIN TRY
                EXEC msdb.dbo.sp_start_job @job_id = @job;
                UPDATE dbo.Incident SET ActionAt = GETDATE(), Action = CONCAT(N'Started ', @jobname)
                WHERE IncidentId = @id;
            END TRY
            BEGIN CATCH
                UPDATE dbo.Incident SET ActionAt = GETDATE(), Action = CONCAT(N'Start failed: ', ERROR_MESSAGE())
                WHERE IncidentId = @id;
            END CATCH
        END
    END
    ELSE IF @running = 1 EXEC dbo.usp_ResolveIncident 'AgentStopped', @sub;

    /* --- LatencyBreach (alert only: latency is a symptom, the other checks find causes) --- */
    IF @pendingSec >= @slo OR @lastMs >= @slo * 1000
    BEGIN
        SET @diag = CONCAT(N'SLO ', @slo, N's breached: oldest pending token ', ISNULL(@pendingSec, 0),
                           N's, last measured ', ISNULL(@lastMs, 0), N' ms.');
        EXEC dbo.usp_OpenIncident 'LatencyBreach', @sub, @diag, @id OUTPUT;
    END
    ELSE EXEC dbo.usp_ResolveIncident 'LatencyBreach', @sub;

    FETCH NEXT FROM c INTO @sub, @agent, @job, @jobname, @since;
END
CLOSE c; DEALLOCATE c;
GO
CREATE OR ALTER PROCEDURE dbo.usp_DriftCheckAll
AS
SET NOCOUNT ON;
DECLARE @auto bit = CAST(dbo.fn_Setting(N'AutoRepair') AS bit);
DECLARE @sub sysname, @tables nvarchar(max), @keys int, @outcome varchar(20), @id int, @rows int, @diag nvarchar(1000),
        @runStart datetime2(3), @tn nvarchar(300), @kv nvarchar(400), @kind varchar(10), @n int, @ks sysname, @kt sysname;
DECLARE @dk TABLE (TableName nvarchar(300), KeyValue nvarchar(400), Kind varchar(10));
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT s.SubscriberName FROM dbo.Subscriber s
    WHERE s.IsActive = 1
      AND NOT EXISTS (SELECT 1 FROM dbo.Incident i     -- skip subscribers the health check is working on
                      WHERE i.SubscriberName = s.SubscriberName AND i.ResolvedAt IS NULL
                        AND i.Kind IN ('AgentStopped', 'DataConflict'));
OPEN c; FETCH NEXT FROM c INTO @sub;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @runStart = GETDATE();
        EXEC dbo.usp_CheckDrift @sub, @tables OUTPUT, @keys OUTPUT, @outcome OUTPUT;
        IF @outcome = 'Drift'
        BEGIN
            SET @diag = CONCAT(@keys, N' row(s) differ with no replication error in ', @tables, N'.');
            EXEC dbo.usp_OpenIncident 'SilentDrift', @sub, @diag, @id OUTPUT;
            IF @auto = 1
            BEGIN
                -- repair only the drifted keys, never the whole table (see usp_RepairRow)
                DELETE @dk;
                INSERT @dk (TableName, KeyValue, Kind)
                SELECT dc.TableName, k.KeyValue, k.Kind
                FROM dbo.DriftKey k JOIN dbo.DriftCheck dc ON dc.CheckId = k.CheckId
                WHERE dc.SubscriberName = @sub AND dc.CheckedAt >= @runStart;
                SET @rows = 0;
                DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT TableName, KeyValue, Kind FROM @dk;
                OPEN k; FETCH NEXT FROM k INTO @tn, @kv, @kind;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    SELECT @ks = PARSENAME(@tn, 2), @kt = PARSENAME(@tn, 1),
                           @kind = CASE WHEN @kind = 'Extra' THEN 'delete' ELSE 'sync' END;
                    EXEC dbo.usp_RepairRow @sub, @ks, @kt, @kv, @Mode = @kind, @RowsFixed = @n OUTPUT,
                         @IncidentId = @id, @ErrorText = N'Silent drift: subscriber row differed with no replication error';
                    SET @rows += @n;
                    FETCH NEXT FROM k INTO @tn, @kv, @kind;
                END
                CLOSE k; DEALLOCATE k;
                UPDATE dbo.Incident SET ActionAt = GETDATE(),
                       Action = CONCAT(N'Repaired ', @keys, N' drifted row(s) in ', @tables, N' key by key (', @rows, N' written)')
                WHERE IncidentId = @id;
                EXEC dbo.usp_CheckDrift @sub, @tables OUTPUT, @keys OUTPUT, @outcome OUTPUT;  -- verify
            END
        END
        IF @outcome = 'Clean' EXEC dbo.usp_ResolveIncident 'SilentDrift', @sub;
    END TRY
    BEGIN CATCH
        DECLARE @m nvarchar(2048) = ERROR_MESSAGE();
        RAISERROR(N'ReplMon drift check failed for %s: %s', 10, 1, @sub, @m) WITH LOG;
    END CATCH
    FETCH NEXT FROM c INTO @sub;
END
CLOSE c; DEALLOCATE c;
GO
/* ------------------------------------------------------------------ Agent jobs */
USE msdb;
GO
DECLARE @jobs TABLE (name sysname, cmd nvarchar(400), subday_type int, subday_int int);
INSERT @jobs VALUES
    (N'ReplMon - Tracer tokens', N'EXEC dbo.usp_PostTracerToken; WAITFOR DELAY ''00:00:20''; EXEC dbo.usp_HarvestTracerLatency;', 2, 60),
    (N'ReplMon - Health check',  N'EXEC dbo.usp_HealthCheck;', 2, 30),
    (N'ReplMon - Drift check',   N'EXEC dbo.usp_DriftCheckAll;', 4, 5);
DECLARE @n sysname, @cmd nvarchar(400), @st int, @si int;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name, cmd, subday_type, subday_int FROM @jobs;
OPEN c; FETCH NEXT FROM c INTO @n, @cmd, @st, @si;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @n) EXEC msdb.dbo.sp_delete_job @job_name = @n;
    -- created disabled; build-lab.ps1 enables them once the initial snapshot has been applied
    EXEC msdb.dbo.sp_add_job @job_name = @n, @enabled = 0, @description = N'Hybrid replication lab: ReplMon';
    -- linked-server (distributed) queries need ANSI_NULLS and ANSI_WARNINGS on
    SET @cmd = N'SET ANSI_NULLS ON; SET ANSI_WARNINGS ON; SET QUOTED_IDENTIFIER ON; ' + @cmd;
    EXEC msdb.dbo.sp_add_jobstep @job_name = @n, @step_name = N'Run', @subsystem = N'TSQL',
         @database_name = N'ReplMon', @command = @cmd;
    EXEC msdb.dbo.sp_add_jobschedule @job_name = @n, @name = N'Schedule', @freq_type = 4, @freq_interval = 1,
         @freq_subday_type = @st, @freq_subday_interval = @si;
    EXEC msdb.dbo.sp_add_jobserver @job_name = @n;
    FETCH NEXT FROM c INTO @n, @cmd, @st, @si;
END
CLOSE c; DEALLOCATE c;
GO
