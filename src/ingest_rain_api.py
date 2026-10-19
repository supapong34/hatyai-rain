"""
ขั้นที่ 1: ดึงข้อมูลฝนรายชั่วโมงจาก Open-Meteo API -> เก็บไฟล์ดิบ -> โหลดเข้า SQL Server

โหมดการรัน
  incremental : ดึงย้อนหลัง N วันจาก forecast API (ค่าเริ่มต้น 3 วัน) ใช้รันทุกชั่วโมง
  backfill    : ดึงช่วงวันที่กำหนดจาก archive API ใช้เติมข้อมูลย้อนหลังครั้งแรก

ตัวอย่าง
  python src/ingest_rain_api.py --mode incremental
  python src/ingest_rain_api.py --mode backfill --start 2026-09-01 --end 2026-10-15

ทำไมใช้ "ดึงทับช่วงล่าสุด + upsert" แทน watermark:
  ค่าฝนของชั่วโมงล่าสุดอาจถูกปรับแก้ภายหลัง การดึงย้อนหลังไม่กี่วันแล้ว upsert
  ทำให้ได้ค่าล่าสุดเสมอ และรันซ้ำกี่ครั้งข้อมูลก็ไม่ซ้ำ (idempotent)

Upsert ใน SQL Server ใช้ MERGE + OUTPUT $action เพื่อนับแถวที่เพิ่มใหม่กับแถวที่อัปเดตแยกกัน
"""
import argparse
import json
import logging
import os
import time
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd
import requests
from dotenv import load_dotenv
from requests.adapters import HTTPAdapter
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL
from urllib3.util.retry import Retry

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ingest_rain_api")

ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw" / "open_meteo"
LOCATIONS_FILE = ROOT / "config" / "locations.csv"

TZ = "Asia/Bangkok"
HOURLY_VARS = ["precipitation", "rain", "temperature_2m"]
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
PIPELINE = "rain_api"


# ---------------------------------------------------------------- setup
def get_engine():
    # URL.create จัดการอักขระพิเศษในรหัสผ่าน (เช่น @ หรือ !) ให้ปลอดภัย
    url = URL.create(
        "mssql+pymssql",
        username=os.getenv("MSSQL_USER", "sa"),
        password=os.environ["MSSQL_SA_PASSWORD"],
        host=os.getenv("MSSQL_HOST", "localhost"),
        port=int(os.getenv("MSSQL_PORT", "1433")),
        database=os.environ["MSSQL_DB"],
    )
    return create_engine(url)


def get_session() -> requests.Session:
    """HTTP session ที่ retry อัตโนมัติเมื่อเจอปัญหาชั่วคราว (เน็ตหลุด, 429, 5xx)"""
    retry = Retry(total=3, backoff_factor=2,
                  status_forcelist=[429, 500, 502, 503, 504], allowed_methods=["GET"])
    s = requests.Session()
    s.mount("https://", HTTPAdapter(max_retries=retry))
    return s


# ---------------------------------------------------------------- run log
def start_run(engine, mode: str) -> int:
    with engine.begin() as conn:
        return conn.execute(
            text("INSERT INTO meta.pipeline_runs (pipeline, mode) "
                 "OUTPUT INSERTED.run_id VALUES (:p, :m)"),
            {"p": PIPELINE, "m": mode},
        ).scalar_one()


def finish_run(engine, run_id: int, status: str, inserted: int, updated: int, message: str = ""):
    with engine.begin() as conn:
        conn.execute(text("""
            UPDATE meta.pipeline_runs
            SET finished_at = SYSDATETIMEOFFSET(), status = :s,
                rows_inserted = :i, rows_updated = :u, message = :msg
            WHERE run_id = :id"""),
            {"s": status, "i": inserted, "u": updated, "msg": message[:500], "id": run_id})


# ---------------------------------------------------------------- E: extract
def fetch(session, loc, mode: str, past_days: int, start: str = None, end: str = None) -> dict:
    params = {
        "latitude": loc.latitude,
        "longitude": loc.longitude,
        "hourly": ",".join(HOURLY_VARS),
        "timezone": TZ,
    }
    if mode == "incremental":
        url = FORECAST_URL
        params.update(past_days=past_days, forecast_days=1)
    else:
        url = ARCHIVE_URL
        params.update(start_date=start, end_date=end)

    r = session.get(url, params=params, timeout=60)
    r.raise_for_status()
    return r.json()


def year_windows(start: str, end: str) -> list[tuple[str, str]]:
    """แบ่งช่วง backfill เป็นก้อนละไม่เกิน 1 ปีปฏิทิน (chunking)
    ลดขนาด response ต่อครั้ง และถ้าล้ม rerun เฉพาะช่วงนั้นได้"""
    s, e = date.fromisoformat(start), date.fromisoformat(end)
    windows = []
    while s <= e:
        chunk_end = min(date(s.year, 12, 31), e)
        windows.append((s.isoformat(), chunk_end.isoformat()))
        s = date(s.year + 1, 1, 1)
    return windows


def save_raw(payload: dict, location_id: str, run_ts: datetime, suffix: str = "") -> Path:
    """เก็บ response ดิบไว้เสมอ เผื่อย้อนประมวลผลใหม่ (เหมือนชั้น raw ใน data lake)"""
    folder = RAW_DIR / f"ingest_date={run_ts:%Y-%m-%d}"
    folder.mkdir(parents=True, exist_ok=True)
    name = f"{location_id}_{run_ts:%H%M%S}{'_' + suffix if suffix else ''}.json"
    path = folder / name
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return path


# ---------------------------------------------------------------- T: transform
def to_frame(payload: dict, location_id: str, source: str) -> pd.DataFrame:
    h = payload["hourly"]
    df = pd.DataFrame({
        "ts": pd.to_datetime(h["time"]).tz_localize(TZ),   # API ส่งเวลาท้องถิ่นแบบไม่มี timezone
        "precipitation_mm": h["precipitation"],
        "rain_mm": h["rain"],
        "temperature_c": h["temperature_2m"],
    })
    df.insert(0, "location_id", location_id)
    df["source"] = source
    return df


def transform(df: pd.DataFrame, mode: str) -> pd.DataFrame:
    if mode == "incremental":
        now = pd.Timestamp.now(tz=TZ)
        df = df[df["ts"] <= now]                 # ตัดส่วนพยากรณ์อนาคตออก เก็บเฉพาะที่ผ่านมาแล้ว

    missing = df["precipitation_mm"].isna().sum()
    if missing:
        log.warning("drop %d rows with null precipitation", missing)
    df = df.dropna(subset=["precipitation_mm"])

    return df.drop_duplicates(subset=["location_id", "ts"], keep="last")


def validate(df: pd.DataFrame):
    """ตรวจคุณภาพข้อมูล ถ้าไม่ผ่านให้หยุด ไม่โหลดข้อมูลเสียเข้าฐาน"""
    errors = []
    if df["ts"].isna().any():
        errors.append("null ts")
    if (df["precipitation_mm"] < 0).any() or (df["rain_mm"] < 0).any():
        errors.append("negative rainfall")
    if (df["precipitation_mm"] > 300).any():
        errors.append("precipitation > 300 mm/h (unrealistic)")
    if not df["temperature_c"].dropna().between(-5, 50).all():
        errors.append("temperature out of range")
    if errors:
        raise ValueError(f"data quality failed: {errors}")


# ---------------------------------------------------------------- L: load
def load(engine, df: pd.DataFrame) -> tuple[int, int]:
    """โหลดเข้าตารางพัก แล้ว MERGE ใน transaction เดียว ล้มกลางทางจะ rollback ทั้งหมด
    คืนค่า (จำนวนแถวที่เพิ่มใหม่, จำนวนแถวที่อัปเดต)"""
    cols = ["location_id", "ts", "precipitation_mm", "rain_mm", "temperature_c", "source"]
    stg = df[cols].copy()
    stg["ts"] = stg["ts"].dt.tz_localize(None)   # เวลาไทยแบบไม่มี tz แล้วค่อยใส่ +07:00 ตอน MERGE

    with engine.begin() as conn:
        stg.to_sql("_stg_open_meteo", conn, schema="raw",
                   if_exists="replace", index=False, chunksize=500)
        actions = conn.execute(text("""
            MERGE raw.open_meteo_hourly AS t
            USING (
                SELECT location_id,
                       TODATETIMEOFFSET(ts, 420) AS ts,      -- 420 นาที = +07:00
                       precipitation_mm, rain_mm, temperature_c, source
                FROM raw._stg_open_meteo
            ) AS s
            ON t.location_id = s.location_id AND t.ts = s.ts
            WHEN MATCHED THEN UPDATE SET
                precipitation_mm = s.precipitation_mm,
                rain_mm          = s.rain_mm,
                temperature_c    = s.temperature_c,
                source           = s.source,
                ingested_at      = SYSDATETIMEOFFSET()
            WHEN NOT MATCHED THEN
                INSERT (location_id, ts, precipitation_mm, rain_mm, temperature_c, source)
                VALUES (s.location_id, s.ts, s.precipitation_mm, s.rain_mm, s.temperature_c, s.source)
            OUTPUT $action;""")).fetchall()
        conn.execute(text("DROP TABLE raw._stg_open_meteo"))

    inserted = sum(1 for (a,) in actions if a == "INSERT")
    updated = sum(1 for (a,) in actions if a == "UPDATE")
    return inserted, updated


# ---------------------------------------------------------------- main
def parse_args():
    p = argparse.ArgumentParser(description="Ingest hourly rainfall from Open-Meteo")
    p.add_argument("--mode", choices=["incremental", "backfill"], default="incremental")
    p.add_argument("--past-days", type=int, default=3, help="incremental: ดึงย้อนหลังกี่วัน")
    p.add_argument("--start", help="backfill: YYYY-MM-DD")
    p.add_argument("--end", help="backfill: YYYY-MM-DD")
    p.add_argument("--only", help="ดึงเฉพาะ location_id ที่ระบุ คั่นด้วยจุลภาค เช่น hatyai,sadao")
    args = p.parse_args()
    if args.mode == "backfill":
        if not (args.start and args.end):
            p.error("backfill ต้องระบุ --start และ --end")
        if date.fromisoformat(args.start) > date.fromisoformat(args.end):
            p.error("--start ต้องไม่เกิน --end")
    return args


def main():
    args = parse_args()
    engine = get_engine()
    session = get_session()
    locations = pd.read_csv(LOCATIONS_FILE)
    if args.only:
        wanted = [x.strip() for x in args.only.split(",")]
        locations = locations[locations["location_id"].isin(wanted)]
        if locations.empty:
            raise SystemExit(f"ไม่พบ location_id: {args.only}")
    source = "forecast" if args.mode == "incremental" else "archive"
    run_ts = datetime.now(ZoneInfo(TZ))

    run_id = start_run(engine, args.mode)
    total_ins = total_upd = 0
    try:
        for loc in locations.itertuples():
            windows = (year_windows(args.start, args.end)
                       if args.mode == "backfill" else [(None, None)])
            for w_start, w_end in windows:
                payload = fetch(session, loc, args.mode, args.past_days, w_start, w_end)
                suffix = w_start[:4] if w_start else ""
                raw_path = save_raw(payload, loc.location_id, run_ts, suffix)
                df = transform(to_frame(payload, loc.location_id, source), args.mode)
                validate(df)
                ins, upd = load(engine, df)
                total_ins += ins
                total_upd += upd
                label = f"{loc.location_id} {w_start[:4]}" if w_start else loc.location_id
                log.info("%-19s +%d new, %d updated (raw: %s)", label, ins, upd, raw_path.name)
                time.sleep(0.5)   # สุภาพกับ API ฟรี ไม่ยิงถี่เกินไป
        finish_run(engine, run_id, "success", total_ins, total_upd)
        log.info("run %d done: %d new, %d updated", run_id, total_ins, total_upd)
    except Exception as e:
        finish_run(engine, run_id, "failed", total_ins, total_upd, str(e))
        log.exception("run %d failed", run_id)
        raise


if __name__ == "__main__":
    main()
