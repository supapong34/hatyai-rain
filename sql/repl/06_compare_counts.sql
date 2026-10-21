/* รันบนทั้ง mssql และ mssql2 แล้วเทียบผล ต้องเท่ากันทุกตาราง (data reconciliation) */
USE rain_dw;
SELECT 'raw.open_meteo_hourly'   AS tbl, COUNT(*) AS rows, MAX(ingested_at) AS last_change FROM raw.open_meteo_hourly
UNION ALL SELECT 'raw.water_level_readings', COUNT(*), MAX(ingested_at) FROM raw.water_level_readings
UNION ALL SELECT 'meta.file_loads',          COUNT(*), MAX(loaded_at)   FROM meta.file_loads
UNION ALL SELECT 'meta.pipeline_runs',       COUNT(*), MAX(started_at)  FROM meta.pipeline_runs;
