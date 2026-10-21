/* รันบน: mssql ลบ replication ทั้งหมด (ข้อมูลในตารางไม่หาย) ใช้เมื่ออยากเริ่มฝึกใหม่ */
USE rain_dw;
GO
IF EXISTS (SELECT 1 FROM syspublications WHERE name = N'pub_rain_raw')
BEGIN
    EXEC sp_dropsubscription @publication = N'pub_rain_raw', @article = N'all', @subscriber = N'all';
    EXEC sp_droppublication @publication = N'pub_rain_raw';
END
EXEC sp_replicationdboption @dbname = N'rain_dw', @optname = N'publish', @value = N'false';
GO
USE master;
GO
IF EXISTS (SELECT 1 FROM sys.servers WHERE is_distributor = 1)
    EXEC sp_dropdistributor @no_checks = 1, @ignore_distributor = 1;
GO
PRINT 'replication removed';
