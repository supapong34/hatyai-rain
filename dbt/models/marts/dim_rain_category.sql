-- เกณฑ์ฝนรายวันของกรมอุตุนิยมวิทยา (seeds/rain_categories.csv)
-- ช่วงเป็นแบบ min < ปริมาณฝน <= max เพื่อไม่ให้มีช่องว่าง เช่น 10.05 มม. ตกอยู่ในช่วงใดช่วงหนึ่งเสมอ
select category_id, name_th, name_en, min_mm, max_mm
from {{ ref('rain_categories') }}
