/* 04-subscription.sql  (publisher) - one push subscription
   Tokens: {{SUBSCRIBER}} {{SUB_DB}} {{SUB_LOGIN}} {{SUB_PWD}}
   {{SUBSCRIBER}} must be the name replication can resolve from the distributor:
   the container hostname for on-prem, or <mi>.public.<zone>.database.windows.net,3342 for MI. */
USE SalesDemo;
GO
IF NOT EXISTS (SELECT 1 FROM dbo.syssubscriptions WHERE srvname = N'{{SUBSCRIBER}}' AND dest_db = N'{{SUB_DB}}')
BEGIN
    EXEC sys.sp_addsubscription
         @publication = N'pub_SalesDemo', @subscriber = N'{{SUBSCRIBER}}',
         @destination_db = N'{{SUB_DB}}', @subscription_type = N'Push',
         @sync_type = N'automatic', @article = N'all', @update_mode = N'read only',
         @subscriber_type = 0;

    EXEC sys.sp_addpushsubscription_agent
         @publication = N'pub_SalesDemo', @subscriber = N'{{SUBSCRIBER}}',
         @subscriber_db = N'{{SUB_DB}}',
         @job_login = NULL, @job_password = NULL,
         @subscriber_security_mode = 0, @subscriber_login = N'{{SUB_LOGIN}}', @subscriber_password = N'{{SUB_PWD}}',
         @frequency_type = 64,            -- start with SQL Agent, run continuously
         @frequency_interval = 0, @frequency_relative_interval = 0,
         @frequency_recurrence_factor = 0, @frequency_subday = 0, @frequency_subday_interval = 0,
         @active_start_time_of_day = 0, @active_end_time_of_day = 235959,
         @active_start_date = 0, @active_end_date = 99991231,
         @dts_package_location = N'Distributor';
END
GO
