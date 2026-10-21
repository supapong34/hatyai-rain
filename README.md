# Hat Yai Rain — SQL Server Data Platform

ระบบฐานข้อมูล SQL Server สำหรับข้อมูลฝน ระดับน้ำ และอุปกรณ์สถานีวัดน้ำของจังหวัดสงขลา
รับข้อมูลจาก API และไฟล์ Excel ตรวจคุณภาพก่อนโหลด แปลงข้อมูลด้วย T-SQL และ dbt
ตั้งเวลาด้วย SQL Server Agent และ Airflow และส่งสำเนาไปอีก server ด้วย Transactional Replication

## ภาพรวม

```
Open-Meteo API ──┐
Excel ระดับน้ำ ───┼──> [mssql :1433]  raw / meta ──> rpt, marts
CSV อุปกรณ์ ─────┘          │
                            └── Transactional Replication ──> [mssql2 :1434]  raw / meta (read-only)
```

| ข้อมูล | ปริมาณ | เข้าระบบโดย | รอบ |
|---|---|---|---|
| ฝนรายชั่วโมง 16 อำเภอ (2021–ปัจจุบัน) | ~814,000 แถว | Python + Airflow | ทุกชั่วโมง |
| ระดับน้ำ 4 สถานี (ข้อมูลจำลอง) | รายวัน | Python + Airflow | ทุก 5 นาที |
| ทะเบียนอุปกรณ์ (ข้อมูลจำลอง) | master data | T-SQL BULK INSERT + SQL Agent | ทุก 15 นาที |

## ฐานข้อมูลทำอะไร

| server | schema | หน้าที่ |
|---|---|---|
| mssql | `raw` | ข้อมูลที่ผ่านการตรวจแล้ว มี primary key ทุกตาราง โหลดด้วย MERGE รันซ้ำได้ไม่เกิดข้อมูลซ้ำ |
| mssql | `meta` | log ทุกการรัน (`pipeline_runs`) และทุกไฟล์ที่เข้ามา (`file_loads`) |
| mssql | `ref`, `snapshots` | master data: อำเภอ สถานี เกณฑ์ฝน และประวัติแบบ SCD Type 2 |
| mssql | `marts` | Star Schema: `dim_location`, `dim_date`, `dim_station`, `dim_rain_category`, `fact_rainfall_hourly`, `fact_rainfall_daily`, `fact_water_level` |
| mssql | `rpt` | ตารางรายงาน `monthly_rain` จาก stored procedure |
| mssql2 | `raw`, `meta` | replica อ่านอย่างเดียวสำหรับทีมอื่น ไม่กระทบ server หลัก |

## SQL ที่ใช้

| เทคนิค | ใช้ทำอะไร | ไฟล์ |
|---|---|---|
| MERGE + OUTPUT `$action` | upsert และนับ insert / update แยกกัน | `sql/lab/lab2_usp_build_monthly_rain.sql` |
| Temp table (`#temp`) + index | พักข้อมูลกลางทางใน stored procedure | `sql/lab/lab2_usp_build_monthly_rain.sql` |
| BULK INSERT + dynamic SQL | อ่านไฟล์ CSV จากไดรฟ์กลาง | `sql/lab/lab4_station_equipment.sql` |
| `EXISTS (... EXCEPT ...)` | อัปเดตเฉพาะแถวที่ค่าเปลี่ยน รองรับ NULL | `sql/lab/lab4_station_equipment.sql` |
| `TRY/CATCH` + `XACT_ABORT` + `THROW` | rollback ทั้งก้อนและบันทึก error ลง log | `sql/lab/*.sql` |
| Filtered unique index | กันไฟล์ซ้ำเฉพาะสถานะที่โหลดสำเร็จ | `sql/02_water_level.sql` |
| `DATETIMEOFFSET`, `SWITCHOFFSET` | เก็บเวลาพร้อม timezone ตัดวันตามเวลาไทย | `sql/init.sql` |
| Window function | ฝนสะสม 3 / 7 วัน | `dbt/models/marts/fact_rainfall_daily.sql` |
| Login, Role, GRANT / DENY ระดับ schema | แยกสิทธิ์ ETL กับนักวิเคราะห์ | `sql/security/roles.sql` |
| Ownership chaining | ให้สิทธิ์รัน procedure แทนสิทธิ์เขียนตาราง | `sql/security/roles.sql` |
| SQL Server Agent Job | ตั้งเวลารัน procedure และโหลดไฟล์ | `sql/jobs/` |
| Transactional Replication | ส่ง 5 ตารางไป server ที่สอง แบบ push subscription | `sql/repl/` |

## Jobs

| job | เครื่องมือ | รอบ | ทำอะไร |
|---|---|---|---|
| load equipment csv | SQL Server Agent | 15 นาที | BULK INSERT ไฟล์อุปกรณ์ แปลงเป็นพิมพ์ใหญ่ ตรวจ และ MERGE |
| rpt - build monthly rain | SQL Server Agent | 07:00 | สร้างรายงานฝนรายเดือน |
| Log Reader / Distribution Agent | SQL Server Agent | ต่อเนื่อง | replication ไป mssql2 |
| `rain_api_hourly` | Airflow | ทุกชั่วโมง | ดึงฝนจาก API และตรวจความครบ 24 ชั่วโมง |
| `water_level_inbox` | Airflow | 5 นาที | โหลดไฟล์ Excel ระดับน้ำ |
| `dbt_build_daily` | Airflow | 06:30 | สร้าง Star Schema และรัน data tests |

## Data Quality

- ตรวจระดับไฟล์ (sheet, หัวคอลัมน์, ไฟล์เสีย) และระดับแถว (ค่าว่าง, ช่วงค่า, สถานีมีจริง)
- กันไฟล์ซ้ำด้วย SHA-256
- แถวที่ไม่ผ่านถูกแยกเก็บพร้อมเหตุผล (`*_errors.csv`, `raw.station_equipment_rejects`)
- ตรวจความครบรายวันใน Airflow และ dbt tests 27 ตัว

## สิ่งที่ทำแล้ว

- [x] Ingestion จาก API และไฟล์ Excel พร้อม data quality
- [x] Star Schema ด้วย dbt พร้อม SCD Type 2 และ data tests
- [x] Security: login, role, สิทธิ์ระดับ schema
- [x] ELT ด้วย stored procedure + temp table + MERGE
- [x] SQL Server Agent Job
- [x] BULK INSERT จากไฟล์ที่เจ้าหน้าที่กรอก
- [x] Transactional Replication ไป server ที่สอง
- [x] Orchestration ด้วย Airflow

## Setup

ต้องมี Docker, Python 3.10+ และ SSMS

```bash
cp .env.example .env                 # ตั้งรหัส sa
docker compose up -d                 # mssql, mssql2, airflow
./sqlrun.sh rain_mssql sql/init.sql
./sqlrun.sh rain_mssql sql/02_water_level.sql

python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python src/ingest_rain_api.py --mode backfill --start 2021-01-01 --end 2026-10-16
```

จากนั้นรันไฟล์ใน `sql/security/`, `sql/lab/`, `sql/jobs/` ผ่าน SSMS และตั้ง replication ตาม `sql/repl/`

| เครื่องมือ | เชื่อมต่อ |
|---|---|
| SSMS server หลัก | `localhost,1433` |
| SSMS server replica | `localhost,1434` |
| Airflow | http://localhost:8080 |

## Data Source

[Open-Meteo](https://open-meteo.com) ข้อมูลจากแบบจำลองสภาพอากาศ ใช้งานฟรีสำหรับงานที่ไม่ใช่เชิงพาณิชย์
พิกัดใน `config/locations.csv` เป็นค่าโดยประมาณของแต่ละอำเภอ ข้อมูลระดับน้ำและอุปกรณ์เป็นข้อมูลจำลอง
