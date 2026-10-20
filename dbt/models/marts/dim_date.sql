-- ตารางวันที่ 2020-01-01 ถึง 2030-12-31 สร้างจากตัวเลขลำดับ (tally)
with numbers as (
    select top (4018) row_number() over (order by (select null)) - 1 as n
    from sys.all_columns a cross join sys.all_columns b
),
dates as (
    select dateadd(day, n, cast('2020-01-01' as date)) as d from numbers
)
select
    year(d) * 10000 + month(d) * 100 + day(d)             as date_key,
    d                                                     as [date],
    year(d)                                               as [year],
    year(d) + 543                                         as year_be,
    datepart(quarter, d)                                  as [quarter],
    month(d)                                              as [month],
    case month(d)
        when 1 then N'มกราคม' when 2 then N'กุมภาพันธ์' when 3 then N'มีนาคม'
        when 4 then N'เมษายน' when 5 then N'พฤษภาคม' when 6 then N'มิถุนายน'
        when 7 then N'กรกฎาคม' when 8 then N'สิงหาคม' when 9 then N'กันยายน'
        when 10 then N'ตุลาคม' when 11 then N'พฤศจิกายน' else N'ธันวาคม' end as month_name_th,
    day(d)                                                as [day],
    (datediff(day, '1900-01-01', d) % 7) + 1              as day_of_week,     -- 1 = จันทร์ ไม่ขึ้นกับ DATEFIRST ของ server
    case when datediff(day, '1900-01-01', d) % 7 >= 5 then 1 else 0 end as is_weekend,
    case when month(d) >= 10 then year(d) + 1 else year(d) end + 543 as fiscal_year_be  -- ปีงบประมาณไทย ต.ค.-ก.ย.
from dates
