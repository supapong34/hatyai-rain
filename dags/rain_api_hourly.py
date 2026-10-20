"""ดึงฝนรายชั่วโมงจาก Open-Meteo ทุกชั่วโมง แล้วตรวจว่าข้อมูลเมื่อวานครบ 24 ชั่วโมงทุกอำเภอ"""
from datetime import timedelta

import pendulum
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import dag, task

PROJECT = "/opt/airflow/project"
TZ = "Asia/Bangkok"


@dag(
    dag_id="rain_api_hourly",
    schedule="10 * * * *",                      # นาทีที่ 10 ของทุกชั่วโมง
    start_date=pendulum.datetime(2026, 10, 1, tz=TZ),
    catchup=False,                              # ไม่ต้องรันย้อนหลังรอบที่พลาด (incremental ดึงย้อน 3 วันอยู่แล้ว)
    max_active_runs=1,                          # กันสองรอบทับกัน
    default_args={"retries": 3, "retry_delay": timedelta(minutes=5)},
    tags=["hatyai-rain", "api"],
    doc_md=__doc__,
)
def rain_api_hourly():
    ingest = BashOperator(
        task_id="ingest_open_meteo",
        bash_command=f"python {PROJECT}/src/ingest_rain_api.py --mode incremental",
        execution_timeout=timedelta(minutes=15),
    )

    @task(retries=0)
    def check_yesterday_complete():
        """data completeness check: ทุกอำเภอต้องมีครบ 24 ชั่วโมงของเมื่อวาน (เวลาไทย)"""
        import sys
        sys.path.insert(0, f"{PROJECT}/src")
        import pandas as pd
        from sqlalchemy import text
        from ingest_rain_api import LOCATIONS_FILE, get_engine

        today = pendulum.now(TZ).start_of("day")
        start, end = today.subtract(days=1), today
        expected = set(pd.read_csv(LOCATIONS_FILE)["location_id"])

        with get_engine().connect() as conn:
            rows = conn.execute(text("""
                SELECT location_id, COUNT(*) AS hours
                FROM raw.open_meteo_hourly
                WHERE ts >= CAST(:s AS DATETIMEOFFSET) AND ts < CAST(:e AS DATETIMEOFFSET)
                GROUP BY location_id"""),
                {"s": start.format("YYYY-MM-DD HH:mm:ss Z"), "e": end.format("YYYY-MM-DD HH:mm:ss Z")}).all()

        hours = {r.location_id: r.hours for r in rows}
        problems = {loc: hours.get(loc, 0) for loc in expected if hours.get(loc, 0) != 24}
        if problems:
            raise ValueError(f"{start.to_date_string()} ไม่ครบ 24 ชั่วโมง: {problems}")
        print(f"{start.to_date_string()} ครบ 24 ชั่วโมงทั้ง {len(expected)} อำเภอ")

    ingest >> check_yesterday_complete()


rain_api_hourly()
