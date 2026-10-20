{#- ค่าเริ่มต้นของ dbt ตั้งชื่อ schema เป็น "dbo_marts" (target + custom)
    macro นี้เปลี่ยนให้ใช้ชื่อที่กำหนดตรง ๆ เช่น marts, stg, ref -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}{{ target.schema }}{%- else -%}{{ custom_schema_name | trim }}{%- endif -%}
{%- endmacro %}
