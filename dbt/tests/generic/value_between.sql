{#- ค่าต้องอยู่ในช่วงที่เป็นไปได้ (ค่าว่างไม่นับ ใช้ not_null ตรวจแยก) -#}
{% test value_between(model, column_name, min_value, max_value) %}
select *
from {{ model }}
where {{ column_name }} < {{ min_value }} or {{ column_name }} > {{ max_value }}
{% endtest %}
