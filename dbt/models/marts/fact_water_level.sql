-- grain: 1 สถานี x 1 การอ่านค่า
select
    r.station_id,
    year(r.date_th) * 10000 + month(r.date_th) * 100 + day(r.date_th) as date_key,
    r.date_th,
    r.time_th,
    r.reading_ts,
    r.level_m,
    s.warning_level_m,
    s.critical_level_m,
    case when r.level_m >= s.critical_level_m then 'critical'
         when r.level_m >= s.warning_level_m  then 'watch'
         else 'normal' end                                          as level_status,
    case when r.level_m >= s.critical_level_m then N'วิกฤต'
         when r.level_m >= s.warning_level_m  then N'เฝ้าระวัง'
         else N'ปกติ' end                                            as level_status_th,
    r.source_file
from {{ ref('stg_water_level') }} r
join {{ ref('dim_station') }} s on s.station_id = r.station_id
