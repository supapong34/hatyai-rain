/* =====================================================================
   Lab 4: โหลดไฟล์ที่เจ้าหน้าที่กรอกเองด้วย T-SQL ล้วน
   Excel (พิมพ์เล็ก) -> Save As CSV UTF-8 -> BULK INSERT -> #temp
   -> transform เป็นพิมพ์ใหญ่ + ตรวจข้อมูล -> MERGE เข้า raw.station_equipment
   -> replication ส่งต่อไป mssql2 (localhost,1434) อัตโนมัติ

   รันบน: localhost,1433 ด้วย sa แล้วกด F5
   ไฟล์ต้นทาง: R:\equipment\inbox\equipment.csv
               (ใน container เห็นเป็น /data/raindrop/equipment/inbox/equipment.csv)
   ===================================================================== */
USE rain_dw;
GO

-- ---------------------------------------------------------------------
-- 1) ตารางปลายทาง: 1 แถว = อุปกรณ์ 1 ชิ้น
-- ---------------------------------------------------------------------
IF OBJECT_ID('raw.station_equipment') IS NULL
CREATE TABLE raw.station_equipment (
    equipment_code  VARCHAR(30)       NOT NULL,
    station_id      VARCHAR(10)       NOT NULL,
    equipment_type  VARCHAR(30)       NOT NULL,
    brand           VARCHAR(50)       NULL,
    serial_no       VARCHAR(50)       NULL,
    install_date    DATE              NULL,
    status          VARCHAR(20)       NOT NULL,
    source_file     NVARCHAR(400)     NOT NULL,
    loaded_at       DATETIMEOFFSET(3) NOT NULL DEFAULT SYSDATETIMEOFFSET(),
    CONSTRAINT pk_station_equipment PRIMARY KEY (equipment_code)   -- replication บังคับต้องมี PK
);
GO

-- แถวที่ไม่ผ่านการตรวจ เก็บไว้ให้เจ้าหน้าที่แก้ (ไม่ replicate)
IF OBJECT_ID('raw.station_equipment_rejects') IS NULL
CREATE TABLE raw.station_equipment_rejects (
    reject_id       INT IDENTITY(1,1) PRIMARY KEY,
    run_id          INT               NOT NULL,
    equipment_code  NVARCHAR(100)     NULL,
    station_id      NVARCHAR(100)     NULL,
    status          NVARCHAR(100)     NULL,
    install_date    NVARCHAR(100)     NULL,
    reason          NVARCHAR(400)     NOT NULL,
    rejected_at     DATETIMEOFFSET(3) NOT NULL DEFAULT SYSDATETIMEOFFSET()
);
GO

-- ---------------------------------------------------------------------
-- 2) procedure โหลดไฟล์
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE raw.usp_load_equipment
    @file NVARCHAR(400) = N'/data/raindrop/equipment/inbox/equipment.csv'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @run_id INT, @ins INT = 0, @upd INT = 0, @bad INT = 0, @sql NVARCHAR(MAX);

    INSERT INTO meta.pipeline_runs (pipeline, mode) VALUES ('usp_load_equipment', 'csv');
    SET @run_id = SCOPE_IDENTITY();

    BEGIN TRY
        -- ---------- E: อ่านไฟล์เข้า #temp ทุกคอลัมน์เป็นข้อความ รับได้ทุกค่าก่อนแล้วค่อยตรวจ ----------
        CREATE TABLE #stg (
            equipment_code NVARCHAR(100), station_id NVARCHAR(100), equipment_type NVARCHAR(100),
            brand NVARCHAR(100), serial_no NVARCHAR(100), install_date NVARCHAR(100), status NVARCHAR(100)
        );

        -- BULK INSERT ไม่รับตัวแปรเป็นชื่อไฟล์ จึงต้องประกอบเป็น dynamic SQL
        -- REPLACE ' เป็น '' กัน SQL injection จากชื่อไฟล์
        SET @sql = N'BULK INSERT #stg FROM ''' + REPLACE(@file, N'''', N'''''') + N'''
                     WITH (FORMAT = ''CSV'',      -- รองรับค่าที่มี , อยู่ในเครื่องหมายคำพูด
                           FIRSTROW = 2,           -- ข้ามหัวตาราง (BOM ของ CSV UTF-8 อยู่บรรทัดนี้ จึงไม่กระทบ)
                           TABLOCK);';
        -- หมายเหตุ: CODEPAGE ใช้ไม่ได้บน SQL Server for Linux ข้อมูลภาษาอังกฤษจึงไม่ต้องระบุ
        EXEC sp_executesql @sql;      -- #stg สร้างนอก dynamic SQL จึงมองเห็นได้

        -- CSV จาก Excel บน Windows จบบรรทัดด้วย \r\n แต่ Linux ตัดที่ \n จึงเหลือ \r ติดคอลัมน์สุดท้าย
        UPDATE #stg SET status = REPLACE(status, CHAR(13), '');

        -- ---------- T: ทำความสะอาด + แปลงเป็นพิมพ์ใหญ่ ----------
        SELECT
            UPPER(TRIM(equipment_code))                         AS equipment_code,
            UPPER(TRIM(station_id))                             AS station_id,
            UPPER(TRIM(equipment_type))                         AS equipment_type,
            NULLIF(UPPER(TRIM(brand)), '')                      AS brand,
            NULLIF(UPPER(TRIM(serial_no)), '')                  AS serial_no,
            COALESCE(TRY_CONVERT(date, TRIM(install_date), 23),    -- 2026-03-15
                     TRY_CONVERT(date, TRIM(install_date), 103))   -- 15/03/2026
                                                                AS install_date_raw,
            UPPER(TRIM(status))                                 AS status,
            install_date                                        AS install_date_text
        INTO #clean
        FROM #stg
        WHERE NULLIF(TRIM(equipment_code), '') IS NOT NULL;     -- ตัดแถวว่าง

        -- Excel ตั้งภาษาไทยมักบันทึกปี พ.ศ. (2569) -> แปลงเป็น ค.ศ.
        UPDATE #clean
        SET    install_date_raw = DATEADD(YEAR, -543, install_date_raw)
        WHERE  YEAR(install_date_raw) > 2400;

        -- ---------- ตรวจข้อมูล: แถวผิดย้ายไปตาราง rejects ----------
        ;WITH checked AS (
            SELECT c.*,
                   CONCAT_WS('; ',
                       CASE WHEN ws.station_id IS NULL THEN 'unknown station_id' END,
                       CASE WHEN c.status NOT IN ('ACTIVE', 'INACTIVE', 'REPAIR') THEN 'invalid status' END,
                       CASE WHEN c.install_date_raw IS NULL AND NULLIF(TRIM(c.install_date_text), '') IS NOT NULL
                            THEN 'invalid install_date' END,
                       CASE WHEN COUNT(*) OVER (PARTITION BY c.equipment_code) > 1 THEN 'duplicate equipment_code' END
                   ) AS reason
            FROM #clean c
            LEFT JOIN ref.water_stations ws ON ws.station_id = c.station_id
        )
        SELECT * INTO #checked FROM checked;

        INSERT INTO raw.station_equipment_rejects (run_id, equipment_code, station_id, status, install_date, reason)
        SELECT @run_id, equipment_code, station_id, status, install_date_text, reason
        FROM   #checked
        WHERE  reason <> '';
        SET @bad = @@ROWCOUNT;

        -- ---------- L: MERGE เฉพาะแถวที่ผ่าน ----------
        DECLARE @actions TABLE (act NVARCHAR(10));
        BEGIN TRANSACTION;

        MERGE raw.station_equipment AS t
        USING (SELECT * FROM #checked WHERE reason = '') AS s
            ON t.equipment_code = s.equipment_code
        -- EXISTS + EXCEPT = เทียบทุกคอลัมน์แบบนับ NULL ด้วย (t.brand <> s.brand ใช้กับ NULL ไม่ได้)
        WHEN MATCHED AND EXISTS (SELECT s.station_id, s.equipment_type, s.brand, s.serial_no, s.install_date_raw, s.status
                                 EXCEPT
                                 SELECT t.station_id, t.equipment_type, t.brand, t.serial_no, t.install_date, t.status) THEN
            UPDATE SET station_id = s.station_id, equipment_type = s.equipment_type, brand = s.brand,
                       serial_no = s.serial_no, install_date = s.install_date_raw, status = s.status,
                       source_file = @file, loaded_at = SYSDATETIMEOFFSET()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (equipment_code, station_id, equipment_type, brand, serial_no, install_date, status, source_file)
            VALUES (s.equipment_code, s.station_id, s.equipment_type, s.brand, s.serial_no, s.install_date_raw, s.status, @file)
        OUTPUT $action INTO @actions;

        COMMIT TRANSACTION;

        SELECT @ins = SUM(CASE WHEN act = 'INSERT' THEN 1 ELSE 0 END),
               @upd = SUM(CASE WHEN act = 'UPDATE' THEN 1 ELSE 0 END)
        FROM   @actions;
        SET @ins = ISNULL(@ins, 0);
        SET @upd = ISNULL(@upd, 0);

        UPDATE meta.pipeline_runs
        SET    finished_at = SYSDATETIMEOFFSET(), status = 'success',
               rows_inserted = @ins, rows_updated = @upd,
               message = CONCAT(@bad, ' rejected rows')
        WHERE  run_id = @run_id;

        PRINT CONCAT('usp_load_equipment: +', @ins, ' new, ', @upd, ' updated, ', @bad, ' rejected');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        UPDATE meta.pipeline_runs
        SET    finished_at = SYSDATETIMEOFFSET(), status = 'failed', message = LEFT(ERROR_MESSAGE(), 500)
        WHERE  run_id = @run_id;
        THROW;
    END CATCH
END;
GO

PRINT 'raw.usp_load_equipment is ready';
