/* สร้างฐานข้อมูล schema และตาราง (รันซ้ำได้ ไม่พัง)
   วิธีรัน: เปิดไฟล์นี้ใน SSMS แล้วกด F5 */

IF DB_ID('rain_dw') IS NULL
    CREATE DATABASE rain_dw;
GO

USE rain_dw;
GO

-- แยก schema ตามชั้นข้อมูล
IF SCHEMA_ID('raw')  IS NULL EXEC('CREATE SCHEMA raw');   -- ข้อมูลจากต้นทาง แทบไม่แปลง
IF SCHEMA_ID('meta') IS NULL EXEC('CREATE SCHEMA meta');  -- log การรันของ pipeline
GO

-- grain: 1 พิกัด ต่อ 1 ชั่วโมง
IF OBJECT_ID('raw.open_meteo_hourly') IS NULL
CREATE TABLE raw.open_meteo_hourly (
    location_id       VARCHAR(50)       NOT NULL,
    ts                DATETIMEOFFSET(0) NOT NULL,   -- เก็บเวลาพร้อม timezone
    precipitation_mm  DECIMAL(6,2)      NULL,
    rain_mm           DECIMAL(6,2)      NULL,
    temperature_c     DECIMAL(5,2)      NULL,
    source            VARCHAR(20)       NOT NULL,   -- forecast หรือ archive
    ingested_at       DATETIMEOFFSET(3) NOT NULL
        CONSTRAINT df_open_meteo_ingested DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT pk_open_meteo_hourly PRIMARY KEY (location_id, ts)  -- ใช้ MERGE ให้ idempotent
);
GO

IF OBJECT_ID('meta.pipeline_runs') IS NULL
CREATE TABLE meta.pipeline_runs (
    run_id         INT IDENTITY(1,1) PRIMARY KEY,
    pipeline       VARCHAR(50)       NOT NULL,
    mode           VARCHAR(20)       NOT NULL,
    started_at     DATETIMEOFFSET(3) NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    finished_at    DATETIMEOFFSET(3) NULL,
    status         VARCHAR(20)       NOT NULL DEFAULT 'running',
    rows_inserted  INT               NULL,
    rows_updated   INT               NULL,
    message        NVARCHAR(500)     NULL
);
GO

PRINT 'rain_dw is ready';
