/* query สำหรับฝึกใน SSMS — เลือกทีละก้อนแล้วกด F5 */
USE rain_dw;
GO

-- 1. สถานะการรันล่าสุด
SELECT TOP 10 run_id, mode, status, rows_inserted, rows_updated, started_at, message
FROM meta.pipeline_runs
ORDER BY run_id DESC;

-- 2. ฝนสะสม 24 ชั่วโมงล่าสุด
SELECT location_id, SUM(precipitation_mm) AS rain_24h_mm
FROM raw.open_meteo_hourly
WHERE ts > DATEADD(HOUR, -24, SYSDATETIMEOFFSET())
GROUP BY location_id;

-- 3. ชั่วโมงที่ฝนหนักที่สุดของแต่ละพิกัด (window function)
WITH ranked AS (
    SELECT location_id, ts, precipitation_mm,
           DENSE_RANK() OVER (PARTITION BY location_id ORDER BY precipitation_mm DESC) AS rk
    FROM raw.open_meteo_hourly
)
SELECT * FROM ranked WHERE rk = 1;

-- 4. ฝนรายวันตามเวลาไทย + ระดับฝนตามเกณฑ์กรมอุตุฯ
SELECT location_id,
       CAST(SWITCHOFFSET(ts, '+07:00') AS date) AS day_th,
       COUNT(*)              AS hours,
       SUM(precipitation_mm) AS rain_mm,
       MAX(precipitation_mm) AS peak_hour_mm,
       CASE
           WHEN SUM(precipitation_mm) = 0      THEN N'ไม่มีฝน'
           WHEN SUM(precipitation_mm) <= 10    THEN N'เล็กน้อย'
           WHEN SUM(precipitation_mm) <= 35    THEN N'ปานกลาง'
           WHEN SUM(precipitation_mm) <= 90    THEN N'หนัก'
           ELSE N'หนักมาก'
       END AS rain_category
FROM raw.open_meteo_hourly
GROUP BY location_id, CAST(SWITCHOFFSET(ts, '+07:00') AS date)
ORDER BY location_id, day_th;

-- 5. ตรวจความครบถ้วน (reconciliation)
SELECT source, COUNT(*) AS rows, MIN(ts) AS first_ts, MAX(ts) AS last_ts
FROM raw.open_meteo_hourly
GROUP BY source;
