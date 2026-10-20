select
    s.station_id,
    s.name_th,
    s.location_id,
    l.name_th          as location_name_th,
    s.warning_level_m,
    s.critical_level_m
from {{ ref('water_stations') }} s
left join {{ ref('dim_location') }} l
    on l.location_id = s.location_id and l.is_current = 1
