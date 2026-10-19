# Hat Yai Rain

Data pipeline สำหรับติดตามปริมาณฝนและระดับน้ำในพื้นที่หาดใหญ่และจังหวัดสงขลา
ฝึกงาน Data Engineering ครบวงจร: ดึง API, รับไฟล์ Excel, Data Quality, Star Schema, Orchestration และ Dashboard

## Architecture (เป้าหมาย)

```
Open-Meteo API ──(ทุกชั่วโมง)──┐
                               ├─> raw (JSON) ─> SQL Server raw ─> dbt ─> Star Schema ─> Power BI
inbox/*.xlsx ──(วางไฟล์)───────┘
```

## Roadmap

- [x] **ขั้น 1** ดึงฝนรายชั่วโมงจาก Open-Meteo โหลดเข้า SQL Server (incremental + backfill)
- [ ] **ขั้น 2** รับไฟล์ Excel ระดับน้ำผ่านโฟลเดอร์ inbox พร้อม validate
- [ ] **ขั้น 3** Orchestration ด้วย Airflow
- [ ] **ขั้น 4** dbt แปลงเป็น Star Schema พร้อม tests และ snapshot (SCD2)
- [ ] **ขั้น 5** Power BI dashboard

## Data Source

[Open-Meteo](https://open-meteo.com) ข้อมูลจากแบบจำลองสภาพอากาศ ไม่ใช่ค่าจากสถานีวัดโดยตรง
ใช้งานฟรีสำหรับงานที่ไม่ใช่เชิงพาณิชย์ ไม่ต้องมี API key
พิกัดใน `config/locations.csv` เป็นค่าโดยประมาณของแต่ละอำเภอ

## Design Decisions

| เรื่อง | การตัดสินใจ | เหตุผล |
|---|---|---|
| Grain | 1 พิกัด ต่อ 1 ชั่วโมง | ตรงกับความละเอียดของ API |
| Incremental | ดึงย้อนหลัง 3 วันทุกรอบ + upsert | ค่าล่าสุดอาจถูกปรับแก้ จึงดึงทับแทนใช้ watermark |
| Idempotency | `PRIMARY KEY (location_id, ts)` + `MERGE` | รันซ้ำแล้วข้อมูลไม่ซ้ำ |
| Load metrics | `MERGE ... OUTPUT $action` | แยกนับแถวที่เพิ่มใหม่กับแถวที่อัปเดต |
| Raw layer | เก็บ JSON ดิบทุกครั้ง | ย้อนประมวลผลใหม่ได้โดยไม่ต้องเรียก API |
| Timezone | `DATETIMEOFFSET` | เก็บเวลาพร้อม offset +07:00 กันความสับสนเรื่องเวลา |
| Data quality | หยุดทั้งรอบเมื่อพบค่าผิดปกติ | ไม่ให้ข้อมูลเสียเข้าฐาน |
| Observability | `meta.pipeline_runs` | ดูสถานะ จำนวนแถว และข้อผิดพลาดย้อนหลัง |

## Setup

ต้องมี Docker, Python 3.10+ และ SSMS (ถ้าจะดูข้อมูลผ่านหน้าจอ)

```bash
cp .env.example .env            # แล้วแก้รหัสผ่าน sa
docker compose up -d            # เปิด SQL Server 2022 (Developer edition)
docker ps                       # รอจนขึ้น (healthy)

# สร้างฐานข้อมูลและตาราง (หรือเปิด sql/init.sql ใน SSMS แล้วกด F5)
docker exec rain_mssql bash -c '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -i /sql/init.sql'

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
# เติมข้อมูลย้อนหลังครั้งแรก
python src/ingest_rain_api.py --mode backfill --start 2026-09-01 --end 2026-10-15

# ดึงข้อมูลล่าสุด (ใช้รันทุกชั่วโมง)
python src/ingest_rain_api.py --mode incremental
```

## Check (SSMS)

เชื่อมต่อด้วย Server `localhost,1433`, SQL Server Authentication, login `sa`
และติ๊ก **Trust server certificate** จากนั้นเปิด `sql/queries.sql`

## Project Structure

```
config/locations.csv     พิกัดที่ต้องการดึงข้อมูล
sql/init.sql             สร้างฐานข้อมูล schema และตาราง
sql/queries.sql          query ตัวอย่างสำหรับฝึกใน SSMS
src/ingest_rain_api.py   pipeline ขั้นที่ 1
data/raw/                ไฟล์ดิบ (ไม่ขึ้น git)
```
