-- grain: 1 อำเภอ x 1 ชั่วโมง (~800,000 แถว) จึงใช้ incremental:
-- รอบแรกสร้างทั้งตาราง รอบถัดไปประมวลผลเฉพาะ 3 วันล่าสุด (ทับช่วงเดียวกับ ingestion)
{{ config(
    materialized='incremental',
    unique_key=['location_id', 'ts']
) }}

select
    h.location_id,
    l.location_sk,
    year(h.date_th) * 10000 + month(h.date_th) * 100 + day(h.date_th) as date_key,
    h.date_th,
    h.hour_th,
    h.ts,
    h.precipitation_mm,
    h.rain_mm,
    h.temperature_c,
    h.source
from {{ ref('stg_rain_hourly') }} h
left join {{ ref('dim_location') }} l
    on  l.location_id = h.location_id
    and h.date_th >= l.valid_from
    and h.date_th <  l.valid_to          -- as-of join: ใช้เวอร์ชันของอำเภอที่มีผล ณ วันนั้น
{% if is_incremental() %}
where h.ts >= (select dateadd(day, -3, max(ts)) from {{ this }})
{% endif %}
