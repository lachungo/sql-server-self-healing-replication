/* 03-publication.sql  (publisher)
   Tokens: {{SA_PWD}}
   Transactional publication tuned for "add articles later without a full reinit":
   immediate_sync = false and allow_anonymous = false. */
USE SalesDemo;
GO
EXEC sys.sp_replicationdboption @dbname = N'SalesDemo', @optname = N'publish', @value = N'true';
GO
IF NOT EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'pub_SalesDemo')
BEGIN
    EXEC sys.sp_addlogreader_agent
         @job_login = NULL, @job_password = NULL,
         @publisher_security_mode = 0, @publisher_login = N'sa', @publisher_password = N'{{SA_PWD}}';

    EXEC sys.sp_addpublication
         @publication = N'pub_SalesDemo',
         @description = N'Hybrid replication lab: 2 on-prem subscribers + Azure SQL Managed Instance',
         @status = N'active', @repl_freq = N'continuous', @sync_method = N'concurrent',
         @allow_push = N'true', @allow_pull = N'false',
         @independent_agent = N'true', @immediate_sync = N'false', @allow_anonymous = N'false',
         @replicate_ddl = 1, @retention = 0;

    EXEC sys.sp_addpublication_snapshot
         @publication = N'pub_SalesDemo', @frequency_type = 1,
         @job_login = NULL, @job_password = NULL,
         @publisher_security_mode = 0, @publisher_login = N'sa', @publisher_password = N'{{SA_PWD}}';
END
GO
/* Articles. schema_option 0x803509B = the transactional default (0x803509F) minus 0x04,
   so subscriber key columns are created WITHOUT the IDENTITY property.
   Read-only subscribers never generate keys, and it lets the repair procedures
   re-insert missing rows at a subscriber without IDENTITY_INSERT. */
DECLARE @t TABLE (name sysname PRIMARY KEY);
INSERT @t VALUES (N'Customer'), (N'Product'), (N'SalesOrder'), (N'SalesOrderLine');
DECLARE @name sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @t;
OPEN c; FETCH NEXT FROM c INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.sysarticles WHERE name = @name)
        EXEC sys.sp_addarticle
             @publication = N'pub_SalesDemo', @article = @name,
             @source_owner = N'dbo', @source_object = @name,
             @destination_owner = N'dbo', @destination_table = @name,
             @type = N'logbased', @schema_option = 0x000000000803509B,
             -- 'none', not 'manual': 'manual' makes replication script IDENTITY (NOT FOR REPLICATION)
             -- at the subscriber and silently forces schema option 0x04 back on.
             @pre_creation_cmd = N'drop', @identityrangemanagementoption = N'none',
             @status = 24;
    FETCH NEXT FROM c INTO @name;
END
CLOSE c; DEALLOCATE c;
GO
