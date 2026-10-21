/* รันบน: mssql (publisher)
   Transactional replication: Log Reader Agent อ่าน transaction log ของ rain_dw
   ส่งทุก INSERT/UPDATE/DELETE ของตารางที่เลือก (article) ไป distribution */
USE rain_dw;
GO
EXEC sp_replicationdboption @dbname = N'rain_dw', @optname = N'publish', @value = N'true';
GO

-- Log Reader Agent: หนึ่งตัวต่อหนึ่งฐานข้อมูลที่ publish
IF NOT EXISTS (SELECT 1 FROM distribution.dbo.MSlogreader_agents WHERE publisher_db = N'rain_dw')
    EXEC sp_addlogreader_agent
        @job_login = NULL, @job_password = NULL,
        @publisher_security_mode = 0,
        @publisher_login = N'sa',
        @publisher_password = N'$(SA_PASSWORD)';
GO

IF NOT EXISTS (SELECT 1 FROM syspublications WHERE name = N'pub_rain_raw')
BEGIN
    EXEC sp_addpublication
        @publication = N'pub_rain_raw',
        @description = N'Transactional publication of raw and meta tables',
        @repl_freq = N'continuous',          -- continuous = transactional (snapshot = ส่งทั้งก้อนตามรอบ)
        @status = N'active',
        @allow_push = N'true',
        @independent_agent = N'true',
        @immediate_sync = N'false',
        @retention = 0;

    -- Snapshot Agent: สร้างสำเนาเริ่มต้นของทุกตารางให้ subscriber ก่อนส่งการเปลี่ยนแปลงต่อเนื่อง
    EXEC sp_addpublication_snapshot
        @publication = N'pub_rain_raw',
        @frequency_type = 1,                 -- 1 = รันครั้งเดียวเมื่อสั่ง
        @publisher_security_mode = 0,
        @publisher_login = N'sa',
        @publisher_password = N'$(SA_PASSWORD)';
END
GO

-- article = ตารางที่ส่ง ต้องมี primary key ทุกตัว (transactional บังคับ)
DECLARE @articles TABLE (owner sysname, name sysname);
INSERT INTO @articles VALUES
    (N'raw', N'open_meteo_hourly'),
    (N'raw', N'water_level_readings'),
    (N'meta', N'file_loads'),
    (N'meta', N'pipeline_runs'),
    (N'raw', N'station_equipment');      -- Lab 4: ตารางอุปกรณ์จากไฟล์ Excel

DECLARE @owner sysname, @name sysname, @article sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT owner, name FROM @articles;
OPEN c;
FETCH NEXT FROM c INTO @owner, @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @article = CONCAT(@owner, '_', @name);
    IF NOT EXISTS (SELECT 1 FROM sysarticles WHERE name = @article)
        EXEC sp_addarticle
            @publication = N'pub_rain_raw',
            @article = @article,
            @source_owner = @owner,
            @source_object = @name,
            @destination_owner = @owner,
            @destination_table = @name,
            @type = N'logbased',
            @pre_creation_cmd = N'drop',     -- ฝั่ง subscriber ถ้ามีตารางชื่อนี้อยู่ ให้ลบแล้วสร้างใหม่ตอน snapshot
            @schema_option = 0x000000000803509D,
            @identityrangemanagementoption = N'manual';
    FETCH NEXT FROM c INTO @owner, @name;
END
CLOSE c; DEALLOCATE c;
GO
PRINT 'publication pub_rain_raw is ready';
