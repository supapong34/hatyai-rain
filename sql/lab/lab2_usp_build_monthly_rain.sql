/* =====================================================================
   Lab 2: Stored Procedure ELT ด้วย #temp + MERGE
   สร้างตารางรายงานฝนรายเดือนต่ออำเภอจากข้อมูลดิบรายชั่วโมง
   วิธีรัน: เปิดไฟล์นี้ใน SSMS (เชื่อมต่อ localhost,1433 ด้วย sa) แล้วกด F5
   ===================================================================== */
USE rain_dw;
GO

-- ---------------------------------------------------------------------
-- 1) schema และตารางปลายทาง (รันซ้ำได้)
-- ---------------------------------------------------------------------
IF SCHEMA_ID('rpt') IS NULL EXEC('CREATE SCHEMA rpt');   -- rpt = ตารางรายงานสำหรับผู้ใช้
GO

IF OBJECT_ID('rpt.monthly_rain') IS NULL
CREATE TABLE rpt.monthly_rain (
    location_id     VARCHAR(50)       NOT NULL,
    [year]          SMALLINT          NOT NULL,
    [month]         TINYINT           NOT NULL,
    rain_mm         DECIMAL(8,2)      NOT NULL,   -- ฝนรวมทั้งเดือน
    rainy_days      TINYINT           NOT NULL,   -- จำนวนวันที่ฝน >= 0.1 มม.
    heavy_days      TINYINT           NOT NULL,   -- จำนวนวันฝนหนัก > 35 มม. (เกณฑ์กรมอุตุฯ)
    max_daily_mm    DECIMAL(7,2)      NOT NULL,   -- วันที่ฝนมากที่สุดของเดือน
    days_recorded   TINYINT           NOT NULL,
    is_complete     BIT               NOT NULL,   -- ครบทุกวัน และทุกวันครบ 24 ชั่วโมง
    updated_at      DATETIMEOFFSET(3) NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT pk_monthly_rain PRIMARY KEY (location_id, [year], [month])   -- grain: อำเภอ x เดือน
);
GO

-- ---------------------------------------------------------------------
-- 2) stored procedure
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE rpt.usp_build_monthly_rain
    @months_back INT = 3          -- คำนวณใหม่ย้อนหลังกี่เดือน (ครั้งแรกใส่ 72 = ทั้งหมด)
AS
BEGIN
    SET NOCOUNT ON;               -- ไม่ส่งข้อความ "(n rows affected)" กลับไปทุกคำสั่ง ลด network traffic
    SET XACT_ABORT ON;            -- error ใด ๆ ใน transaction = rollback ทั้งก้อนอัตโนมัติ

    DECLARE @run_id   INT,
            @inserted INT = 0,
            @updated  INT = 0,
            @today    DATE = CAST(SWITCHOFFSET(SYSDATETIMEOFFSET(), '+07:00') AS date),  -- วันนี้ตามเวลาไทย
            @from     DATE;

    -- วันแรกของเดือนที่ย้อนกลับไป @months_back เดือน
    SET @from = DATEADD(MONTH, -@months_back, DATEFROMPARTS(YEAR(@today), MONTH(@today), 1));

    -- บันทึกการรันในตาราง log เดียวกับ pipeline Python
    INSERT INTO meta.pipeline_runs (pipeline, mode)
    VALUES ('usp_build_monthly_rain', CONCAT('months_back=', @months_back));
    SET @run_id = SCOPE_IDENTITY();   -- IDENTITY ที่เพิ่งสร้างใน scope นี้ (ไม่โดน trigger อื่นรบกวน)

    BEGIN TRY
        -- ---------- ขั้น 1: รวมรายชั่วโมงเป็นรายวัน พักไว้ใน #temp ----------
        SELECT  location_id,
                CAST(SWITCHOFFSET(ts, '+07:00') AS date) AS date_th,
                SUM(precipitation_mm)                    AS rain_mm,
                COUNT(*)                                 AS hours
        INTO    #daily                                   -- SELECT INTO สร้าง temp table จากผลลัพธ์ทันที
        FROM    raw.open_meteo_hourly
        WHERE   ts >= TODATETIMEOFFSET(CAST(@from  AS datetime2), 420)   -- 420 นาที = +07:00
          AND   ts <  TODATETIMEOFFSET(CAST(@today AS datetime2), 420)   -- ไม่รวมวันนี้ที่ยังไม่จบวัน
        GROUP BY location_id, CAST(SWITCHOFFSET(ts, '+07:00') AS date);

        -- temp table สร้าง index ได้ ช่วยให้ขั้นถัดไปที่ group by อำเภอเร็วขึ้น
        CREATE CLUSTERED INDEX ix_daily ON #daily (location_id, date_th);

        -- ---------- ขั้น 2: รวมรายวันเป็นรายเดือน ----------
        SELECT  location_id,
                YEAR(date_th)                                        AS [year],
                MONTH(date_th)                                       AS [month],
                SUM(rain_mm)                                         AS rain_mm,
                SUM(CASE WHEN rain_mm >= 0.1 THEN 1 ELSE 0 END)      AS rainy_days,
                SUM(CASE WHEN rain_mm >  35  THEN 1 ELSE 0 END)      AS heavy_days,
                MAX(rain_mm)                                         AS max_daily_mm,
                COUNT(*)                                             AS days_recorded,
                CASE WHEN COUNT(*) = DAY(EOMONTH(MIN(date_th)))      -- จำนวนวันเท่ากับวันในเดือนนั้น
                      AND MIN(hours) = 24                            -- และไม่มีวันไหนขาดชั่วโมง
                     THEN 1 ELSE 0 END                               AS is_complete
        INTO    #monthly
        FROM    #daily
        GROUP BY location_id, YEAR(date_th), MONTH(date_th);

        -- ---------- ขั้น 3: MERGE เข้าตารางรายงาน ----------
        DECLARE @actions TABLE (act NVARCHAR(10));   -- table variable เก็บผลของ MERGE

        BEGIN TRANSACTION;

        MERGE rpt.monthly_rain AS t
        USING #monthly AS s
            ON  t.location_id = s.location_id
            AND t.[year]      = s.[year]
            AND t.[month]     = s.[month]
        -- อัปเดตเฉพาะแถวที่ค่าเปลี่ยนจริง ไม่เขียนทับแถวเดิมเปล่า ๆ (ลด log และ replication traffic)
        WHEN MATCHED AND (   t.rain_mm       <> s.rain_mm
                          OR t.days_recorded <> s.days_recorded
                          OR t.is_complete   <> s.is_complete) THEN
            UPDATE SET rain_mm       = s.rain_mm,
                       rainy_days    = s.rainy_days,
                       heavy_days    = s.heavy_days,
                       max_daily_mm  = s.max_daily_mm,
                       days_recorded = s.days_recorded,
                       is_complete   = s.is_complete,
                       updated_at    = SYSDATETIMEOFFSET()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (location_id, [year], [month], rain_mm, rainy_days, heavy_days,
                    max_daily_mm, days_recorded, is_complete)
            VALUES (s.location_id, s.[year], s.[month], s.rain_mm, s.rainy_days, s.heavy_days,
                    s.max_daily_mm, s.days_recorded, s.is_complete)
        OUTPUT $action INTO @actions;                 -- เก็บว่าแต่ละแถวเป็น INSERT หรือ UPDATE

        COMMIT TRANSACTION;

        SELECT @inserted = SUM(CASE WHEN act = 'INSERT' THEN 1 ELSE 0 END),
               @updated  = SUM(CASE WHEN act = 'UPDATE' THEN 1 ELSE 0 END)
        FROM   @actions;
        SET @inserted = ISNULL(@inserted, 0);   -- @actions ว่างทั้งตาราง SUM คืน NULL
        SET @updated  = ISNULL(@updated, 0);

        UPDATE meta.pipeline_runs
        SET    finished_at = SYSDATETIMEOFFSET(), status = 'success',
               rows_inserted = @inserted, rows_updated = @updated
        WHERE  run_id = @run_id;

        PRINT CONCAT('usp_build_monthly_rain: +', @inserted, ' new, ', @updated, ' updated');
        -- #daily และ #monthly หายเองเมื่อ procedure จบ ไม่ต้อง DROP
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        UPDATE meta.pipeline_runs
        SET    finished_at = SYSDATETIMEOFFSET(), status = 'failed',
               message = LEFT(ERROR_MESSAGE(), 500)
        WHERE  run_id = @run_id;

        THROW;                    -- ส่ง error ต่อให้ผู้เรียก (Agent Job จะขึ้นว่าล้ม)
    END CATCH
END;
GO

-- ---------------------------------------------------------------------
-- 3) สิทธิ์: ให้ etl รัน procedure ได้ และนักวิเคราะห์อ่านรายงานได้
-- ---------------------------------------------------------------------
GRANT EXECUTE ON OBJECT::rpt.usp_build_monthly_rain TO role_etl;
GRANT SELECT  ON SCHEMA::rpt TO role_analyst;
GO

PRINT 'rpt.usp_build_monthly_rain is ready';
