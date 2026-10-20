-- singular test: 7 วันที่ผ่านมา (ไม่รวมวันนี้) ทุกอำเภอต้องมีครบ 24 ชั่วโมง
-- ตั้งเป็น warn เพราะแจ้งเตือนให้ไปดู ไม่ควรหยุดการสร้างตารางอื่น
{{ config(severity='warn') }}

select location_id, date_th, hours_recorded
from {{ ref('fact_rainfall_daily') }}
where date_th <  cast(switchoffset(sysdatetimeoffset(), '+07:00') as date)
  and date_th >= dateadd(day, -7, cast(switchoffset(sysdatetimeoffset(), '+07:00') as date))
  and hours_recorded <> 24
