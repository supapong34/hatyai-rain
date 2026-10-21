/* รันบน: mssql (publisher) ดูสถานะ agent และวัดความหน่วงด้วย tracer token */
USE rain_dw;
GO
-- job ของ replication ที่ Agent สร้างให้
SELECT j.name, j.enabled, ja.start_execution_date, ja.stop_execution_date
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
LEFT JOIN msdb.dbo.sysjobactivity ja ON ja.job_id = j.job_id
WHERE c.name LIKE 'REPL-%'
ORDER BY j.name;

-- ข้อความล่าสุดจาก Distribution Agent (หา error ได้ที่นี่)
SELECT TOP 10 time, comments
FROM distribution.dbo.MSdistribution_history
ORDER BY time DESC;

-- tracer token: ส่ง "พัสดุทดสอบ" ไปตามท่อ แล้ววัดเวลาที่ใช้แต่ละช่วง
EXEC sp_posttracertoken @publication = N'pub_rain_raw';
WAITFOR DELAY '00:00:10';
DECLARE @t int = (SELECT MAX(tracer_id) FROM distribution.dbo.MStracer_tokens);
EXEC sp_helptracertokenhistory @publication = N'pub_rain_raw', @tracer_id = @t;
-- distributor_latency = publisher -> distribution, subscriber_latency = distribution -> subscriber (วินาที)
