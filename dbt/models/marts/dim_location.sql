-- มิติอำเภอแบบ SCD Type 2 จาก snapshot
-- เวอร์ชันแรกของแต่ละอำเภอให้เริ่ม 1900-01-01 ไม่อย่างนั้นข้อมูลฝนย้อนหลัง
-- ก่อนวันที่รัน snapshot ครั้งแรกจะหา dimension ไม่เจอ
with versions as (
    select
        *,
        row_number() over (partition by location_id order by dbt_valid_from) as version_no
    from {{ ref('snap_locations') }}
)
select
    dbt_scd_id                                                     as location_sk,
    location_id,
    amphoe_code,
    name_th,
    name_en,
    latitude,
    longitude,
    version_no,
    case when version_no = 1 then cast('1900-01-01' as date)
         else cast(dbt_valid_from as date) end                     as valid_from,
    coalesce(cast(dbt_valid_to as date), cast('9999-12-31' as date)) as valid_to,
    case when dbt_valid_to is null then 1 else 0 end               as is_current
from versions
