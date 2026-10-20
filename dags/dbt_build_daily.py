"""สร้าง Star Schema ด้วย dbt ทุกวัน 06:30: ตรวจความสดของข้อมูล แล้ว dbt build (seed, snapshot, model, test)"""
from datetime import timedelta

import pendulum
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import dag

DBT = "cd /opt/airflow/project/dbt && /home/airflow/dbt_venv/bin/dbt"


@dag(
    dag_id="dbt_build_daily",
    schedule="30 6 * * *",
    start_date=pendulum.datetime(2026, 10, 1, tz="Asia/Bangkok"),
    catchup=False,
    max_active_runs=1,
    default_args={"retries": 1, "retry_delay": timedelta(minutes=5)},
    tags=["hatyai-rain", "dbt"],
    doc_md=__doc__,
)
def dbt_build_daily():
    freshness = BashOperator(
        task_id="dbt_source_freshness",
        bash_command=f"{DBT} source freshness --profiles-dir .",
        retries=0,
    )
    build = BashOperator(
        task_id="dbt_build",
        bash_command=f"{DBT} build --profiles-dir .",
        trigger_rule="all_done",       # ข้อมูลไม่สดก็ยังสร้างตาราง แต่ DAG run จะขึ้นสีแดงให้รู้
        execution_timeout=timedelta(minutes=30),
    )
    freshness >> build


dbt_build_daily()
