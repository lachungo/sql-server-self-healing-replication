/* 01-demo-db.sql  (publisher)
   SalesDemo: the published database, seed data, and a continuous workload job
   so latency is measured under load, not on an idle system. */
USE master;
GO
IF DB_ID(N'SalesDemo') IS NULL
    CREATE DATABASE SalesDemo;
GO
ALTER DATABASE SalesDemo SET RECOVERY SIMPLE;   -- lab only; the Log Reader still holds log until it is read
GO
USE SalesDemo;
GO
IF OBJECT_ID(N'dbo.SalesOrderLine') IS NULL
BEGIN
    CREATE TABLE dbo.Customer (
        CustomerID  int IDENTITY(1,1) NOT FOR REPLICATION CONSTRAINT PK_Customer PRIMARY KEY,
        Name        nvarchar(100) NOT NULL,
        Email       nvarchar(200) NOT NULL,
        Region      char(2)       NOT NULL,
        ModifiedAt  datetime2(3)  NOT NULL CONSTRAINT DF_Customer_ModifiedAt DEFAULT SYSUTCDATETIME()
    );
    CREATE TABLE dbo.Product (
        ProductID   int IDENTITY(1,1) NOT FOR REPLICATION CONSTRAINT PK_Product PRIMARY KEY,
        Sku         varchar(20)   NOT NULL CONSTRAINT UQ_Product_Sku UNIQUE,
        Name        nvarchar(100) NOT NULL,
        ListPrice   decimal(10,2) NOT NULL
    );
    CREATE TABLE dbo.SalesOrder (
        OrderID     bigint IDENTITY(1,1) NOT FOR REPLICATION CONSTRAINT PK_SalesOrder PRIMARY KEY,
        CustomerID  int           NOT NULL CONSTRAINT FK_SalesOrder_Customer REFERENCES dbo.Customer(CustomerID),
        OrderDate   datetime2(3)  NOT NULL,
        Status      varchar(12)   NOT NULL,
        Total       decimal(12,2) NOT NULL
    );
    CREATE TABLE dbo.SalesOrderLine (
        OrderID     bigint        NOT NULL CONSTRAINT FK_SalesOrderLine_Order REFERENCES dbo.SalesOrder(OrderID),
        LineNumber      smallint      NOT NULL,
        ProductID   int           NOT NULL CONSTRAINT FK_SalesOrderLine_Product REFERENCES dbo.Product(ProductID),
        Qty         int           NOT NULL,
        UnitPrice   decimal(10,2) NOT NULL,
        CONSTRAINT PK_SalesOrderLine PRIMARY KEY (OrderID, LineNumber)
    );

    -- Seed: 5,000 customers, 200 products, 20,000 orders, ~50,000 lines
    ;WITH n AS (SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT dbo.Customer (Name, Email, Region)
    SELECT CONCAT(N'Customer ', i), CONCAT(N'customer', i, N'@example.com'),
           CHOOSE(i % 5 + 1, 'GA', 'TX', 'NJ', 'AZ', 'OH')
    FROM n WHERE i <= 5000;

    ;WITH n AS (SELECT TOP (200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects)
    INSERT dbo.Product (Sku, Name, ListPrice)
    SELECT CONCAT('SKU-', RIGHT(CONCAT('00000', i), 5)), CONCAT(N'Product ', i), 5 + (i * 7) % 250
    FROM n;

    ;WITH n AS (SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT dbo.SalesOrder (CustomerID, OrderDate, Status, Total)
    SELECT 1 + (i * 37) % 5000, DATEADD(MINUTE, -i * 13, SYSUTCDATETIME()),
           CHOOSE(i % 4 + 1, 'NEW', 'PAID', 'SHIPPED', 'CLOSED'), 0
    FROM n;

    INSERT dbo.SalesOrderLine (OrderID, LineNumber, ProductID, Qty, UnitPrice)
    SELECT o.OrderID, l.LineNumber, 1 + (o.OrderID * l.LineNumber * 11) % 200, 1 + (o.OrderID + l.LineNumber) % 5, p.ListPrice
    FROM dbo.SalesOrder o
    CROSS APPLY (SELECT TOP (1 + o.OrderID % 4) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS smallint) AS LineNumber
                 FROM sys.all_objects) l
    JOIN dbo.Product p ON p.ProductID = 1 + (o.OrderID * l.LineNumber * 11) % 200;

    UPDATE o SET Total = x.Total
    FROM dbo.SalesOrder o
    JOIN (SELECT OrderID, SUM(Qty * UnitPrice) AS Total FROM dbo.SalesOrderLine GROUP BY OrderID) x
      ON x.OrderID = o.OrderID;
END
GO
/* Continuous workload: new orders, status changes, customer edits. Touches only
   recent orders, so old rows stay stable (the chaos tests tamper with old rows). */
CREATE OR ALTER PROCEDURE dbo.usp_Workload @Orders int = 10
AS
SET NOCOUNT ON;
DECLARE @i int = 0, @OrderID bigint, @Lines int;
WHILE @i < @Orders
BEGIN
    INSERT dbo.SalesOrder (CustomerID, OrderDate, Status, Total)
    VALUES (1 + ABS(CHECKSUM(NEWID())) % 5000, SYSUTCDATETIME(), 'NEW', 0);
    SET @OrderID = SCOPE_IDENTITY();
    SET @Lines = 1 + ABS(CHECKSUM(NEWID())) % 4;

    INSERT dbo.SalesOrderLine (OrderID, LineNumber, ProductID, Qty, UnitPrice)
    SELECT @OrderID, l.LineNumber, p.ProductID, 1 + ABS(CHECKSUM(NEWID())) % 5, p.ListPrice
    FROM (SELECT TOP (@Lines) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS smallint) AS LineNumber
          FROM sys.all_objects) l
    CROSS APPLY (SELECT TOP (1) ProductID, ListPrice FROM dbo.Product ORDER BY NEWID()) p;

    UPDATE dbo.SalesOrder
    SET Total = (SELECT SUM(Qty * UnitPrice) FROM dbo.SalesOrderLine WHERE OrderID = @OrderID)
    WHERE OrderID = @OrderID;
    SET @i += 1;
END;

-- advance a few recent orders through the lifecycle
UPDATE TOP (5) dbo.SalesOrder
SET Status = CASE Status WHEN 'NEW' THEN 'PAID' WHEN 'PAID' THEN 'SHIPPED' ELSE 'CLOSED' END
WHERE OrderDate > DATEADD(HOUR, -1, SYSUTCDATETIME()) AND Status <> 'CLOSED';

-- customer edits only on the newest customers (keeps CustomerID <= 1000 stable for chaos tests)
UPDATE dbo.Customer SET ModifiedAt = SYSUTCDATETIME()
WHERE CustomerID = 4000 + ABS(CHECKSUM(NEWID())) % 1000;
GO
/* Agent job: workload every 10 seconds */
USE msdb;
GO
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SalesDemo - Workload')
    EXEC msdb.dbo.sp_delete_job @job_name = N'SalesDemo - Workload';
EXEC msdb.dbo.sp_add_job @job_name = N'SalesDemo - Workload', @enabled = 1,
     @description = N'Hybrid replication lab: continuous OLTP workload on the publisher.';
EXEC msdb.dbo.sp_add_jobstep @job_name = N'SalesDemo - Workload', @step_name = N'Run workload',
     @subsystem = N'TSQL', @database_name = N'SalesDemo', @command = N'EXEC dbo.usp_Workload @Orders = 10;';
EXEC msdb.dbo.sp_add_jobschedule @job_name = N'SalesDemo - Workload', @name = N'Every 10 seconds',
     @freq_type = 4, @freq_interval = 1, @freq_subday_type = 2, @freq_subday_interval = 10;
EXEC msdb.dbo.sp_add_jobserver @job_name = N'SalesDemo - Workload';
GO
