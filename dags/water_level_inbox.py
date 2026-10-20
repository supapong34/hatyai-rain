"""เฝ้าโฟลเดอร์ inbox ทุก 5 นาที ถ้ามีไฟล์ Excel ใหม่ที่พร้อม ให้โหลดเข้า SQL Server"""
import os
import time
from datetime import timedelta
from pathlib import Path

import pendulum
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import dag, task

PROJECT = "/opt/airflow/project"


@dag(
    dag_id="water_level_inbox",
    schedule="*/5 * * * *",
    start_date=pendulum.datetime(2026, 10, 1, tz="Asia/Bangkok"),
    catchup=False,
    max_active_runs=1,                          # ห้ามสองรอบอ่านไฟล์ชุดเดียวกันพร้อมกัน
    default_args={"retries": 1, "retry_delay": timedelta(minutes=2)},
    tags=["hatyai-rain", "excel"],
    doc_md=__doc__,
)
def water_level_inbox():

    @task.short_circuit
    def has_ready_files() -> bool:
        """ไม่มีไฟล์พร้อม = จบรอบนี้เลย (task ถัดไปจะเป็นสถานะ skipped ไม่ใช่ failed)"""
        inbox = Path(os.environ.get("DROP_ROOT", "/data/raindrop")) / "inbox"
        min_age = int(os.environ.get("MIN_FILE_AGE_SEC", "10"))
        now = time.time()
        ready = [f.name for f in inbox.glob("*.xlsx")
                 if not f.name.startswith("~$") and now - f.stat().st_mtime >= min_age]
        print(f"ready files: {len(ready)} {ready[:10]}")
        return bool(ready)

    ingest = BashOperator(
        task_id="ingest_excel_inbox",
        bash_command=f"python {PROJECT}/src/ingest_excel_inbox.py",
        execution_timeout=timedelta(minutes=10),
    )

    has_ready_files() >> ingest


water_level_inbox()
