-- grain: 1 อำเภอ x 1 วัน (เวลาไทย)
with daily as (
    select
        location_id,
        location_sk,
        date_key,
        date_th,
        sum(precipitation_mm)  as rain_mm,
        max(precipitation_mm)  as peak_hour_mm,
        avg(temperature_c)     as avg_temperature_c,
        count(*)               as hours_recorded
    from {{ ref('fact_rainfall_hourly') }}
    group by location_id, location_sk, date_key, date_th
)
select
    d.location_id,
    d.location_sk,
    d.date_key,
    d.date_th,
    d.rain_mm,
    d.peak_hour_mm,
    cast(d.avg_temperature_c as decimal(5,2))                       as avg_temperature_c,
    d.hours_recorded,
    case when d.hours_recorded = 24 then 1 else 0 end               as is_complete,
    -- ฝนสะสมหลายวัน: ดินอิ่มน้ำแล้วน้ำท่วมง่ายขึ้น จึงดูยอดรวม 3 และ 7 วัน
    sum(d.rain_mm) over (partition by d.location_id order by d.date_th
                         rows between 2 preceding and current row)   as rain_3d_mm,
    sum(d.rain_mm) over (partition by d.location_id order by d.date_th
                         rows between 6 preceding and current row)   as rain_7d_mm,
    c.category_id                                                    as rain_category_id
from daily d
left join {{ ref('dim_rain_category') }} c
    on d.rain_mm > c.min_mm and d.rain_mm <= c.max_mm
