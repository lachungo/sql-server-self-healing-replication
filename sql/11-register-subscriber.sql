/* 11-register-subscriber.sql  (publisher)
   ReplMon's own linked server to a subscriber, used for drift checks and repair.
   It is separate from the linked server replication creates for the subscriber name.
   Tokens: {{LS_NAME}} {{DATASRC}} {{SUB_LOGIN}} {{SUB_PWD}} {{SUBSCRIBER}} {{SUB_DB}} {{TIER}} */
USE master;
GO
IF EXISTS (SELECT 1 FROM sys.servers WHERE name = N'{{LS_NAME}}')
    EXEC sys.sp_dropserver @server = N'{{LS_NAME}}', @droplogins = 'droplogins';
-- Lab containers use self-signed certs, so trust the server certificate (lab only).
EXEC sys.sp_addlinkedserver @server = N'{{LS_NAME}}', @srvproduct = N'', @provider = N'MSOLEDBSQL',
     @datasrc = N'{{DATASRC}}', @provstr = N'Encrypt=yes;TrustServerCertificate=yes';
EXEC sys.sp_addlinkedsrvlogin @rmtsrvname = N'{{LS_NAME}}', @useself = N'false', @locallogin = NULL,
     @rmtuser = N'{{SUB_LOGIN}}', @rmtpassword = N'{{SUB_PWD}}';
EXEC sys.sp_serveroption @server = N'{{LS_NAME}}', @optname = N'rpc out', @optvalue = N'true';
EXEC sys.sp_serveroption @server = N'{{LS_NAME}}', @optname = N'data access', @optvalue = N'true';
-- keep INSERT ... EXEC AT from promoting to a distributed (MSDTC) transaction
EXEC sys.sp_serveroption @server = N'{{LS_NAME}}', @optname = N'remote proc transaction promotion', @optvalue = N'false';
GO
USE ReplMon;
GO
MERGE dbo.Subscriber AS t
USING (SELECT N'{{SUBSCRIBER}}' AS SubscriberName, N'{{SUB_DB}}' AS SubscriberDb,
              N'{{LS_NAME}}' AS LinkedServer, '{{TIER}}' AS Tier) AS s
ON t.SubscriberName = s.SubscriberName
WHEN MATCHED THEN UPDATE SET SubscriberDb = s.SubscriberDb, LinkedServer = s.LinkedServer,
                             Tier = s.Tier, IsActive = 1, RegisteredAt = GETDATE()
WHEN NOT MATCHED THEN INSERT (SubscriberName, SubscriberDb, LinkedServer, Tier)
                      VALUES (s.SubscriberName, s.SubscriberDb, s.LinkedServer, s.Tier);
GO
