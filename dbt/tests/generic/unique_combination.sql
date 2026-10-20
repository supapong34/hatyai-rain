{#- generic test ที่เขียนเอง: กลุ่มคอลัมน์นี้ต้องไม่ซ้ำ (ตรวจ grain ของ fact) -#}
{% test unique_combination(model, columns) %}
select {{ columns | join(', ') }}, count(*) as n
from {{ model }}
group by {{ columns | join(', ') }}
having count(*) > 1
{% endtest %}
