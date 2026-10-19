"""
สร้างไฟล์ Excel รายงานระดับน้ำจำลอง เหมือนเจ้าหน้าที่ภาคสนามส่งมาทุกวัน
ข้อมูลทั้งหมดเป็นข้อมูลสมมติ ใช้สำหรับฝึก pipeline เท่านั้น

ตัวอย่าง
  python src/make_sample_excel.py --days 7                 # ไฟล์ปกติย้อนหลัง 7 วัน
  python src/make_sample_excel.py --days 7 --with-errors   # เพิ่มไฟล์ที่มีปัญหาแบบต่าง ๆ
"""
import argparse
import random
import shutil
from datetime import date, datetime, time, timedelta
from pathlib import Path

import pandas as pd

from ingest_excel_inbox import INBOX   # ใช้โฟลเดอร์ inbox เดียวกับ pipeline (ตาม DROP_ROOT ใน .env)

ROOT = Path(__file__).resolve().parents[1]
STATIONS = pd.read_csv(ROOT / "config" / "water_stations.csv")

READ_TIMES = [time(h) for h in (6, 9, 12, 15, 18)]       # อ่านค่าวันละ 5 ครั้ง
RECORDERS = ["สมชาย", "สุดา", "อนุชา", "มาลี"]
HEADERS = ["วันที่", "เวลา", "สถานี", "ระดับน้ำ (ม.)", "ผู้บันทึก"]


def daily_rows(station, day: date, base: float) -> list[list]:
    rows, level = [], base
    for t in READ_TIMES:
        level = max(0.5, level + random.uniform(-0.3, 0.4))
        rows.append([day, t, station.name_th, round(level, 2), random.choice(RECORDERS)])
    return rows


def write_xlsx(path: Path, rows: list[list], headers=HEADERS, sheet="report"):
    pd.DataFrame(rows, columns=headers).to_excel(path, sheet_name=sheet, index=False)
    print("created", path.name)


def make_good_files(days: int) -> list[Path]:
    created = []
    today = date.today()
    for st in STATIONS.itertuples():
        base = st.warning_level_m * 0.6
        for i in range(days, 0, -1):
            day = today - timedelta(days=i)
            path = INBOX / f"water_{st.station_id}_{day.isoformat()}.xlsx"
            write_xlsx(path, daily_rows(st, day, base))
            created.append(path)
    return created


def make_bad_files(good_files: list[Path]):
    today = date.today()
    st = STATIONS.iloc[2]                       # WL03 หาดใหญ่
    yday = today - timedelta(days=1)

    # 1. หัวคอลัมน์ผิด -> ต้องถูกปฏิเสธทั้งไฟล์
    write_xlsx(INBOX / "bad_header.xlsx",
               daily_rows(st, yday, 5.0),
               headers=["วันที่", "เวลา", "สถานี", "ระดับ", "ผู้บันทึก"])

    # 2. บางแถวค่าผิด (ติดลบ, เกินจริง, ว่าง, ชื่อสถานีไม่รู้จัก) -> โหลดได้บางส่วน
    rows = daily_rows(st, yday, 5.0)
    rows[1][3] = -2.0
    rows[2][3] = 99.0
    rows[3][3] = None
    rows[4][2] = "สถานีที่ไม่มีจริง"
    write_xlsx(INBOX / "partial_bad_values.xlsx", rows)

    # 3. วันที่เป็นข้อความ ปี พ.ศ. และเวลาแบบไทย "6.00" -> ต้องแปลงได้
    be = f"{yday.day:02d}/{yday.month:02d}/{yday.year + 543}"
    rows = [[be, f"{t.hour}.00", f"  {st.aliases.split('|')[1]}  ", round(5 + i * 0.1, 2), "สมชาย"]
            for i, t in enumerate(READ_TIMES)]
    write_xlsx(INBOX / "thai_buddhist_dates.xlsx", rows)

    # 4. ไฟล์ซ้ำ เนื้อหาเหมือนไฟล์ปกติแต่ตั้งชื่อใหม่ -> ต้องถูกข้าม
    shutil.copy(good_files[0], INBOX / "water_WL01_resend.xlsx")
    print("created water_WL01_resend.xlsx")

    # 5. ไม่ใช่ไฟล์ Excel จริง -> ต้องถูกปฏิเสธ
    (INBOX / "not_really_excel.xlsx").write_text("this is not an excel file", encoding="utf-8")
    print("created not_really_excel.xlsx")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--with-errors", action="store_true")
    p.add_argument("--seed", type=int, default=None)
    args = p.parse_args()

    random.seed(args.seed)
    INBOX.mkdir(parents=True, exist_ok=True)
    good = make_good_files(args.days)
    if args.with_errors:
        make_bad_files(good)
    print(f"done: files are in {INBOX}")


if __name__ == "__main__":
    main()
