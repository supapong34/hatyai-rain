-- ทำความสะอาดเบา ๆ: แปลงเป็นเวลาไทย แยกวันที่และชั่วโมง ไม่รวมหรือกรองข้อมูล
select
    location_id,
    ts,
    cast(switchoffset(ts, '+07:00') as date)       as date_th,
    datepart(hour, switchoffset(ts, '+07:00'))     as hour_th,
    precipitation_mm,
    rain_mm,
    temperature_c,
    source,
    ingested_at
from {{ source('raw', 'open_meteo_hourly') }}
