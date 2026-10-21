/* รันบน: mssql (publisher) ใช้เมื่อ publication pub_rain_raw มีอยู่แล้ว
   เพิ่มตาราง raw.station_equipment เข้า replication โดยไม่ต้องรื้อของเดิม
   (ถ้ายังไม่เคยตั้ง replication ไม่ต้องใช้ไฟล์นี้ 03_publication.sql ใส่ตารางนี้ไว้แล้ว) */
USE rain_dw;
GO
IF NOT EXISTS (SELECT 1 FROM sysarticles WHERE name = N'raw_station_equipment')
    EXEC sp_addarticle
        @publication = N'pub_rain_raw',
        @article = N'raw_station_equipment',
        @source_owner = N'raw',
        @source_object = N'station_equipment',
        @destination_owner = N'raw',
        @destination_table = N'station_equipment',
        @type = N'logbased',
        @pre_creation_cmd = N'drop',
        @schema_option = 0x000000000803509D,
        @identityrangemanagementoption = N'manual';
GO
-- ผูก article ใหม่เข้ากับ subscription ที่มีอยู่ แล้วสร้าง snapshot เฉพาะตารางใหม่
EXEC sp_refreshsubscriptions @publication = N'pub_rain_raw';
EXEC sp_startpublication_snapshot @publication = N'pub_rain_raw';
GO
PRINT 'raw.station_equipment added to pub_rain_raw';
