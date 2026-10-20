select
    station_id,
    reading_ts,
    cast(switchoffset(reading_ts, '+07:00') as date)   as date_th,
    cast(switchoffset(reading_ts, '+07:00') as time(0)) as time_th,
    level_m,
    recorded_by,
    source_file,
    file_load_id
from {{ source('raw', 'water_level_readings') }}
