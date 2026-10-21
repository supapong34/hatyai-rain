/* รันบน: mssql (publisher + distributor อยู่ server เดียวกัน)
   ตามขั้นตอนของ Microsoft: Configure replication with T-SQL (SQL Server on Linux)
   $(SA_PASSWORD) คือ sqlcmd variable ส่งเข้ามาจาก sqlrun.sh ไม่เขียนรหัสลงไฟล์ */
USE master;
GO
DECLARE @distributor sysname = @@SERVERNAME;          -- ต้องตรงกับ hostname (ดู 00_fix_servername.sql)

IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE is_distributor = 1)
    EXEC sp_adddistributor @distributor = @distributor;

IF DB_ID('distribution') IS NULL
    EXEC sp_adddistributiondb
        @database = N'distribution',
        @log_file_size = 2,
        @deletebatchsize_xact = 5000,
        @deletebatchsize_cmd = 2000,
        @security_mode = 0,                           -- 0 = SQL login, 1 = Windows/AD
        @login = N'sa',
        @password = N'$(SA_PASSWORD)';
GO

-- โฟลเดอร์เก็บ snapshot (สร้างด้วย mkdir ก่อนรันไฟล์นี้)
USE distribution;
GO
DECLARE @snapshotdirectory nvarchar(500) = N'/var/opt/mssql/data/ReplData/';
IF NOT EXISTS (SELECT * FROM sysobjects WHERE name = 'UIProperties' AND type = 'U')
    CREATE TABLE UIProperties (id int);
IF EXISTS (SELECT * FROM ::fn_listextendedproperty('SnapshotFolder', 'user', 'dbo', 'table', 'UIProperties', NULL, NULL))
    EXEC sp_updateextendedproperty N'SnapshotFolder', @snapshotdirectory, 'user', dbo, 'table', 'UIProperties';
ELSE
    EXEC sp_addextendedproperty N'SnapshotFolder', @snapshotdirectory, 'user', dbo, 'table', 'UIProperties';
GO

-- ลงทะเบียน publisher กับ distributor
DECLARE @publisher sysname = @@SERVERNAME;
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.MSdistpublishers WHERE name = @publisher)
    EXEC sp_adddistpublisher
        @publisher = @publisher,
        @distribution_db = N'distribution',
        @security_mode = 0,
        @login = N'sa',
        @password = N'$(SA_PASSWORD)',
        @working_directory = N'/var/opt/mssql/data/ReplData',
        @trusted = N'false',
        @thirdparty_flag = 0,
        @publisher_type = N'MSSQLSERVER';
GO
PRINT 'distributor is ready';
