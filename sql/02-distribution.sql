/* 02-distribution.sql  (publisher = its own distributor)
   Tokens: {{DIST_PWD}} {{SA_PWD}} {{SNAPSHOT_DIR}} */
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE is_distributor = 1)
BEGIN
    DECLARE @srv sysname = @@SERVERNAME;
    EXEC sys.sp_adddistributor @distributor = @srv, @password = N'{{DIST_PWD}}';
    EXEC sys.sp_adddistributiondb
         @database = N'distribution', @security_mode = 0,
         @login = N'sa', @password = N'{{SA_PWD}}',
         @min_distretention = 0, @max_distretention = 72, @history_retention = 48;
END
GO
USE distribution;
GO
-- Snapshot folder (SSMS stores the UI default as an extended property; set it for consistency)
IF OBJECT_ID(N'dbo.UIProperties') IS NULL CREATE TABLE dbo.UIProperties (id int);
IF EXISTS (SELECT 1 FROM ::fn_listextendedproperty(N'SnapshotFolder', N'user', N'dbo', N'table', N'UIProperties', NULL, NULL))
    EXEC sys.sp_updateextendedproperty N'SnapshotFolder', N'{{SNAPSHOT_DIR}}', N'user', N'dbo', N'table', N'UIProperties';
ELSE
    EXEC sys.sp_addextendedproperty N'SnapshotFolder', N'{{SNAPSHOT_DIR}}', N'user', N'dbo', N'table', N'UIProperties';
GO
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.MSdistpublishers WHERE name = @@SERVERNAME)
BEGIN
    DECLARE @pub sysname = @@SERVERNAME;
    EXEC sys.sp_adddistpublisher
         @publisher = @pub, @distribution_db = N'distribution',
         @security_mode = 0, @login = N'sa', @password = N'{{SA_PWD}}',
         @working_directory = N'{{SNAPSHOT_DIR}}', @trusted = N'false',
         @thirdparty_flag = 0, @publisher_type = N'MSSQLSERVER';
END
GO
