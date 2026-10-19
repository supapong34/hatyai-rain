"""
ขั้นที่ 2: รับไฟล์ Excel รายงานระดับน้ำจากโฟลเดอร์ inbox -> ตรวจ -> โหลดเข้า SQL Server

  <DROP_ROOT>/inbox/      วางไฟล์ใหม่ที่นี่
  <DROP_ROOT>/processed/  ไฟล์ที่โหลดสำเร็จ (ทั้งหมดหรือบางส่วน)
  <DROP_ROOT>/rejected/   ไฟล์ที่ถูกปฏิเสธ + ไฟล์ *_errors.csv บอกแถวที่ผิด

  DROP_ROOT ตั้งใน .env เช่น /mnt/c/RainDrop (ไดรฟ์ R: ฝั่ง Windows) ถ้าไม่ตั้งจะใช้ ./data

กติกาการตรวจ
  ระดับไฟล์ : เปิดไม่ได้, ไม่มี sheet "report", หัวคอลัมน์ไม่ครบ  -> ปฏิเสธทั้งไฟล์
  ไฟล์ซ้ำ   : เนื้อหาเหมือนไฟล์ที่เคยโหลดแล้ว (เทียบ SHA-256)   -> ข้าม
  ระดับแถว  : วันเวลาผิด, ไม่รู้จักสถานี, ค่าว่าง/ผิดช่วง         -> ตัดแถวนั้น โหลดที่เหลือ

ตัวอย่าง
  python src/ingest_excel_inbox.py
"""
import hashlib
import logging
import os
import re
import time as _time
import shutil
from datetime import date, datetime, time
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd
from sqlalchemy import text
from sqlalchemy.types import NVARCHAR, VARCHAR

from ingest_rain_api import get_engine   # ใช้การเชื่อมต่อฐานข้อมูลชุดเดียวกับขั้นที่ 1

log = logging.getLogger("ingest_excel_inbox")

ROOT = Path(__file__).resolve().parents[1]
DROP_ROOT = Path(os.getenv("DROP_ROOT") or ROOT / "data")   # get_engine import ด้านบนโหลด .env แล้ว
INBOX = DROP_ROOT / "inbox"
PROCESSED = DROP_ROOT / "processed"
REJECTED = DROP_ROOT / "rejected"
MIN_FILE_AGE_SEC = int(os.getenv("MIN_FILE_AGE_SEC", "10"))   # กันอ่านไฟล์ที่ยังคัดลอกไม่เสร็จ
STATIONS_FILE = ROOT / "config" / "water_stations.csv"

TZ = ZoneInfo("Asia/Bangkok")
SHEET = "report"
COLUMNS = {                       # หัวคอลัมน์ภาษาไทยใน Excel -> ชื่อคอลัมน์ในระบบ
    "วันที่": "reading_date",
    "เวลา": "reading_time",
    "สถานี": "station_raw",
    "ระดับน้ำ (ม.)": "level_m",
    "ผู้บันทึก": "recorded_by",
}
LEVEL_MIN, LEVEL_MAX = 0.0, 20.0


class FileRejected(Exception):
    """ปัญหาระดับไฟล์ ต้องปฏิเสธทั้งไฟล์"""


# ---------------------------------------------------------------- helpers
def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def station_lookup() -> dict[str, str]:
    """แปลงชื่อสถานีทุกแบบที่เป็นไปได้ (ชื่อเต็ม, ชื่อย่อ, ภาษาอังกฤษ) -> station_id"""
    lookup = {}
    for st in pd.read_csv(STATIONS_FILE).itertuples():
        for name in [st.station_id, st.name_th, *str(st.aliases).split("|")]:
            lookup[normalize(name)] = st.station_id
    return lookup


def normalize(name) -> str:
    return re.sub(r"\s+", " ", str(name)).strip().lower()


def parse_date(v) -> date | None:
    if isinstance(v, (datetime, pd.Timestamp)):
        return v.date()
    if isinstance(v, date):
        return v
    if v is None or pd.isna(v):
        return None
    m = re.fullmatch(r"(\d{1,4})[/-](\d{1,2})[/-](\d{1,4})", str(v).strip())
    if not m:
        return None
    a, b, c = (int(x) for x in m.groups())
    day, month, year = (c, b, a) if a > 31 else (a, b, c)   # รองรับทั้ง yyyy-mm-dd และ dd/mm/yyyy
    if year > 2400:                                          # ปี พ.ศ. -> ค.ศ.
        year -= 543
    try:
        return date(year, month, day)
    except ValueError:
        return None


def parse_time(v) -> time | None:
    if isinstance(v, time):
        return v
    if isinstance(v, (datetime, pd.Timestamp)):
        return v.time()
    if isinstance(v, (int, float)) and not pd.isna(v):
        if 0 <= v < 1:                                       # Excel เก็บเวลาเป็นเศษส่วนของวัน
            minutes = round(v * 24 * 60) % (24 * 60)
            return time(minutes // 60, minutes % 60)
        if 1 <= v < 24:                                      # พิมพ์ 6.30 แล้ว Excel แปลงเป็นตัวเลข = 06:30
            h, mi = int(v), round((v - int(v)) * 100)
            return time(h, mi) if mi < 60 else None
        return None
    if v is None or pd.isna(v):
        return None
    m = re.fullmatch(r"(\d{1,2})[:.](\d{2})(?::\d{2})?(?:\s*น\.)?", str(v).strip())  # 06:00, 6.00, 6.00 น.
    if not m:
        return None
    h, mi = int(m.group(1)), int(m.group(2))
    return time(h, mi) if h < 24 and mi < 60 else None


# ---------------------------------------------------------------- E: read
def read_file(path: Path) -> pd.DataFrame:
    try:
        sheets = pd.read_excel(path, sheet_name=None, engine="openpyxl")
    except Exception as e:
        raise FileRejected(f"เปิดไฟล์ไม่ได้: {type(e).__name__}")
    if SHEET not in sheets:
        raise FileRejected(f"ไม่พบ sheet '{SHEET}' (มี {list(sheets)})")
    df = sheets[SHEET]
    df.columns = [str(c).strip() for c in df.columns]
    missing = [c for c in COLUMNS if c not in df.columns]
    if missing:
        raise FileRejected(f"หัวคอลัมน์ไม่ครบ: ขาด {missing}")
    return df[list(COLUMNS)].rename(columns=COLUMNS).dropna(how="all")


# ---------------------------------------------------------------- T: transform + validate
def transform(df: pd.DataFrame, stations: dict) -> tuple[pd.DataFrame, pd.DataFrame]:
    """คืนค่า (แถวที่ผ่าน, แถวที่ไม่ผ่านพร้อมเหตุผล)"""
    now = datetime.now(TZ)
    out, errors = [], []
    for excel_row, r in zip(df.index + 2, df.itertuples(index=False)):   # +2 = หัวตาราง + เริ่มนับ 1
        reasons = []
        d, t = parse_date(r.reading_date), parse_time(r.reading_time)
        if d is None:
            reasons.append(f"วันที่ไม่ถูกต้อง: {r.reading_date}")
        if t is None:
            reasons.append(f"เวลาไม่ถูกต้อง: {r.reading_time}")
        station_id = stations.get(normalize(r.station_raw))
        if station_id is None:
            reasons.append(f"ไม่รู้จักสถานี: {r.station_raw}")
        level = pd.to_numeric(r.level_m, errors="coerce")
        if pd.isna(level):
            reasons.append("ระดับน้ำว่างหรือไม่ใช่ตัวเลข")
        elif not LEVEL_MIN <= level <= LEVEL_MAX:
            reasons.append(f"ระดับน้ำผิดช่วง {LEVEL_MIN}-{LEVEL_MAX} ม.: {level}")

        ts = datetime.combine(d, t, tzinfo=TZ) if d and t else None
        if ts and ts > now:
            reasons.append(f"เวลาอยู่ในอนาคต: {ts}")

        if reasons:
            errors.append({"excel_row": excel_row, "reasons": "; ".join(reasons), **r._asdict()})
        else:
            out.append({"station_id": station_id, "reading_ts": ts, "level_m": round(float(level), 2),
                        "recorded_by": None if pd.isna(r.recorded_by) else str(r.recorded_by).strip()})

    good = pd.DataFrame(out, columns=["station_id", "reading_ts", "level_m", "recorded_by"])
    dup = good.duplicated(subset=["station_id", "reading_ts"], keep="last")
    for _, r in good[dup].iterrows():
        errors.append({"excel_row": None, "reasons": "อ่านค่าซ้ำในไฟล์เดียวกัน (ใช้ค่าล่าสุด)", **r.to_dict()})
    return good[~dup], pd.DataFrame(errors)


# ---------------------------------------------------------------- L: load
def already_loaded(engine, file_hash: str):
    with engine.connect() as conn:
        return conn.execute(text("""
            SELECT TOP 1 file_name FROM meta.file_loads
            WHERE file_hash = :h AND status IN ('loaded', 'partial')"""), {"h": file_hash}).scalar()


def record_file(conn, name, file_hash, status, total=None, ins=None, upd=None, rej=None, msg=None) -> int:
    return conn.execute(text("""
        INSERT INTO meta.file_loads
            (file_name, file_hash, status, rows_total, rows_inserted, rows_updated, rows_rejected, message)
        OUTPUT INSERTED.file_load_id
        VALUES (:n, :h, :s, :t, :i, :u, :r, :m)"""),
        {"n": name, "h": file_hash, "s": status, "t": total, "i": ins, "u": upd, "r": rej,
         "m": (msg or "")[:1000]}).scalar_one()


def load(engine, path: Path, file_hash: str, good: pd.DataFrame, rejected_rows: int, total: int):
    """บันทึก log ไฟล์ + MERGE ข้อมูล ใน transaction เดียว"""
    status = "partial" if rejected_rows else "loaded"
    stg = good.copy()
    stg["reading_ts"] = stg["reading_ts"].map(lambda ts: ts.replace(tzinfo=None))   # เวลาไทยไม่มี tz
    stg["source_file"] = path.name

    with engine.begin() as conn:
        file_load_id = record_file(conn, path.name, file_hash, status, total, rej=rejected_rows)
        stg["file_load_id"] = file_load_id
        stg.to_sql("_stg_water_level", conn, schema="raw", if_exists="replace", index=False,
                   dtype={"station_id": VARCHAR(10), "recorded_by": NVARCHAR(100),
                          "source_file": NVARCHAR(260)})   # NVARCHAR เพื่อเก็บภาษาไทย
        actions = conn.execute(text("""
            MERGE raw.water_level_readings AS t
            USING (
                SELECT station_id, TODATETIMEOFFSET(reading_ts, 420) AS reading_ts,
                       level_m, recorded_by, source_file, file_load_id
                FROM raw._stg_water_level
            ) AS s
            ON t.station_id = s.station_id AND t.reading_ts = s.reading_ts
            WHEN MATCHED THEN UPDATE SET
                level_m = s.level_m, recorded_by = s.recorded_by,
                source_file = s.source_file, file_load_id = s.file_load_id,
                ingested_at = SYSDATETIMEOFFSET()
            WHEN NOT MATCHED THEN
                INSERT (station_id, reading_ts, level_m, recorded_by, source_file, file_load_id)
                VALUES (s.station_id, s.reading_ts, s.level_m, s.recorded_by, s.source_file, s.file_load_id)
            OUTPUT $action;""")).fetchall()
        conn.execute(text("DROP TABLE raw._stg_water_level"))

        ins = sum(1 for (a,) in actions if a == "INSERT")
        upd = sum(1 for (a,) in actions if a == "UPDATE")
        conn.execute(text("""
            UPDATE meta.file_loads SET rows_inserted = :i, rows_updated = :u
            WHERE file_load_id = :id"""), {"i": ins, "u": upd, "id": file_load_id})
    return status, ins, upd


# ---------------------------------------------------------------- file moves
def move(path: Path, folder: Path, tag: str = "") -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(TZ).strftime("%Y%m%d_%H%M%S")
    dest = folder / f"{stamp}__{path.stem}{tag}{path.suffix}"
    shutil.move(str(path), dest)
    return dest


def write_errors(errors: pd.DataFrame, path: Path):
    REJECTED.mkdir(parents=True, exist_ok=True)
    out = REJECTED / f"{datetime.now(TZ):%Y%m%d_%H%M%S}__{path.stem}_errors.csv"
    errors.to_csv(out, index=False, encoding="utf-8-sig")   # utf-8-sig ให้ Excel อ่านภาษาไทยได้
    return out


# ---------------------------------------------------------------- main
def process(engine, path: Path, stations: dict):
    file_hash = sha256(path)

    prev = already_loaded(engine, file_hash)
    if prev:
        with engine.begin() as conn:
            record_file(conn, path.name, file_hash, "skipped", msg=f"เนื้อหาซ้ำกับไฟล์ {prev}")
        move(path, REJECTED, "__duplicate")
        log.warning("SKIP     %-40s duplicate of %s", path.name, prev)
        return

    try:
        df = read_file(path)
    except FileRejected as e:
        with engine.begin() as conn:
            record_file(conn, path.name, file_hash, "rejected", msg=str(e))
        move(path, REJECTED)
        log.error("REJECT   %-40s %s", path.name, e)
        return

    good, errors = transform(df, stations)
    if good.empty:
        with engine.begin() as conn:
            record_file(conn, path.name, file_hash, "rejected", total=len(df), rej=len(errors),
                        msg="ไม่มีแถวที่ผ่านการตรวจ")
        write_errors(errors, path)
        move(path, REJECTED)
        log.error("REJECT   %-40s no valid rows (%d errors)", path.name, len(errors))
        return

    status, ins, upd = load(engine, path, file_hash, good, len(errors), len(df))
    if len(errors):
        write_errors(errors, path)
    move(path, PROCESSED)
    log.info("%-8s %-40s +%d new, %d updated, %d rejected rows",
             status.upper(), path.name, ins, upd, len(errors))


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    INBOX.mkdir(parents=True, exist_ok=True)
    now = _time.time()
    files, waiting = [], []
    for f in sorted(INBOX.glob("*.xlsx")):
        if f.name.startswith("~$"):                   # ไฟล์ล็อกของ Excel ตอนเปิดไฟล์ค้างไว้
            continue
        (waiting if now - f.stat().st_mtime < MIN_FILE_AGE_SEC else files).append(f)
    for f in waiting:
        log.info("WAIT     %-40s เพิ่งถูกวาง รอรอบถัดไป", f.name)
    if not files:
        log.info("no files ready in %s", INBOX)
        return

    engine = get_engine()
    stations = station_lookup()
    for path in files:
        try:
            process(engine, path, stations)
        except Exception:
            log.exception("FAILED   %s (ไฟล์ยังอยู่ใน inbox แก้แล้วรันใหม่ได้)", path.name)
    log.info("done: %d files", len(files))


if __name__ == "__main__":
    main()
