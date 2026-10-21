/* รันบน: mssql (publisher)
   Push subscription: Distribution Agent รันฝั่ง distributor แล้ว "ดัน" ข้อมูลไป mssql2
   ชื่อ mssql2 คือชื่อ service ใน docker compose ซึ่ง container มองเห็นกันผ่าน network เดียวกัน */
USE rain_dw;
GO
-- รันไฟล์นี้ครั้งเดียว ถ้าต้องการเริ่มใหม่ให้รัน 99_teardown.sql ก่อน
EXEC sp_addsubscription
        @publication = N'pub_rain_raw',
        @subscriber = N'mssql2',
        @destination_db = N'rain_dw',
        @subscription_type = N'Push',
        @sync_type = N'automatic',           -- เริ่มด้วย snapshot อัตโนมัติ
        @article = N'all',
        @update_mode = N'read only',         -- subscriber อ่านอย่างเดียว
        @subscriber_type = 0;

    EXEC sp_addpushsubscription_agent
        @publication = N'pub_rain_raw',
        @subscriber = N'mssql2',
        @subscriber_db = N'rain_dw',
        @subscriber_security_mode = 0,
        @subscriber_login = N'sa',
        @subscriber_password = N'$(SA_PASSWORD)',
        @frequency_type = 64;                -- 64 = รันต่อเนื่อง (continuous) ส่งทันทีที่มีการเปลี่ยนแปลง
GO

-- สร้าง snapshot เริ่มต้น (ตาราง 800,000 แถวใช้เวลาสักครู่)
EXEC sp_startpublication_snapshot @publication = N'pub_rain_raw';
GO
PRINT 'subscription created, snapshot started';
