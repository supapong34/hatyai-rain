/* ขั้นที่ 2: ตารางรับข้อมูลระดับน้ำจากไฟล์ Excel (รันซ้ำได้)
   วิธีรัน: เปิดใน SSMS แล้วกด F5 */
USE rain_dw;
GO

-- log ของทุกไฟล์ที่เข้ามา ใช้ทั้งตรวจสอบย้อนหลังและกันโหลดไฟล์ซ้ำ
IF OBJECT_ID('meta.file_loads') IS NULL
CREATE TABLE meta.file_loads (
    file_load_id   INT IDENTITY(1,1) PRIMARY KEY,
    file_name      NVARCHAR(260)     NOT NULL,
    file_hash      CHAR(64)          NOT NULL,   -- SHA-256 ของเนื้อไฟล์
    status         VARCHAR(20)       NOT NULL,   -- loaded | partial | rejected | skipped
    rows_total     INT               NULL,
    rows_inserted  INT               NULL,
    rows_updated   INT               NULL,
    rows_rejected  INT               NULL,
    message        NVARCHAR(1000)    NULL,
    loaded_at      DATETIMEOFFSET(3) NOT NULL DEFAULT SYSDATETIMEOFFSET()
);
GO

-- filtered unique index: ไฟล์เนื้อหาเดียวกันโหลดสำเร็จได้แค่ครั้งเดียว
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_file_loads_hash_ok')
CREATE UNIQUE INDEX ux_file_loads_hash_ok
    ON meta.file_loads (file_hash)
    WHERE status IN ('loaded', 'partial');
GO

-- grain: 1 สถานี ต่อ 1 การอ่านค่า
IF OBJECT_ID('raw.water_level_readings') IS NULL
CREATE TABLE raw.water_level_readings (
    station_id    VARCHAR(10)       NOT NULL,
    reading_ts    DATETIMEOFFSET(0) NOT NULL,
    level_m       DECIMAL(6,2)      NOT NULL,
    recorded_by   NVARCHAR(100)     NULL,
    source_file   NVARCHAR(260)     NOT NULL,   -- lineage: มาจากไฟล์ไหน
    file_load_id  INT               NOT NULL REFERENCES meta.file_loads (file_load_id),
    ingested_at   DATETIMEOFFSET(3) NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT pk_water_level_readings PRIMARY KEY (station_id, reading_ts)
);
GO

PRINT 'water level tables are ready';
