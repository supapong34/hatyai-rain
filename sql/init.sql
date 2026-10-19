-- รันอัตโนมัติครั้งแรกที่สร้าง container PostgreSQL

-- แยก schema ตามชั้นข้อมูล
CREATE SCHEMA IF NOT EXISTS raw;    -- ข้อมูลจากต้นทาง แทบไม่แปลง
CREATE SCHEMA IF NOT EXISTS meta;   -- ข้อมูลของ pipeline เอง (log การรัน)
-- staging / marts จะสร้างด้วย dbt ในขั้นที่ 4

-- grain: 1 พิกัด ต่อ 1 ชั่วโมง
CREATE TABLE IF NOT EXISTS raw.open_meteo_hourly (
    location_id       TEXT        NOT NULL,
    ts                TIMESTAMPTZ NOT NULL,
    precipitation_mm  NUMERIC(6,2),
    rain_mm           NUMERIC(6,2),
    temperature_c     NUMERIC(5,2),
    source            TEXT        NOT NULL,   -- forecast หรือ archive
    ingested_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (location_id, ts)             -- ใช้ upsert ให้ idempotent
);

CREATE TABLE IF NOT EXISTS meta.pipeline_runs (
    run_id       BIGSERIAL PRIMARY KEY,
    pipeline     TEXT        NOT NULL,
    mode         TEXT        NOT NULL,
    started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at  TIMESTAMPTZ,
    status       TEXT        NOT NULL DEFAULT 'running',
    rows_loaded  INT,
    message      TEXT
);
