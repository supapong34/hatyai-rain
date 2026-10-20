"""เติมข้อมูลฝนย้อนหลังแบบสั่งเอง: กด Trigger ในหน้าเว็บแล้วกรอกช่วงวันที่ (และอำเภอถ้าต้องการ)"""
import pendulum
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import Param, dag

PROJECT = "/opt/airflow/project"


@dag(
    dag_id="rain_backfill",
    schedule=None,                              # ไม่ตั้งเวลา รันเมื่อสั่งเท่านั้น
    start_date=pendulum.datetime(2026, 10, 1, tz="Asia/Bangkok"),
    catchup=False,
    max_active_runs=1,
    params={
        "start": Param("2026-10-01", type="string", format="date", description="วันเริ่ม YYYY-MM-DD"),
        "end": Param("2026-10-15", type="string", format="date", description="วันสิ้นสุด YYYY-MM-DD"),
        "only": Param("", type="string", description="location_id คั่นด้วยจุลภาค เว้นว่าง = ทุกอำเภอ"),
    },
    tags=["hatyai-rain", "api", "manual"],
    doc_md=__doc__,
)
def rain_backfill():
    BashOperator(
        task_id="backfill_open_meteo",
        bash_command=(
            f"python {PROJECT}/src/ingest_rain_api.py --mode backfill "
            "--start {{ params.start }} --end {{ params.end }}"
            "{% if params.only %} --only {{ params.only }}{% endif %}"
        ),
    )


rain_backfill()
