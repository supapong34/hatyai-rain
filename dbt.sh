#!/usr/bin/env bash
# รัน dbt ผ่าน container ของ Airflow (มี dbt และ driver พร้อม) เช่น ./dbt.sh build
docker exec -it -w /opt/airflow/project/dbt rain_airflow /home/airflow/dbt_venv/bin/dbt "$@" --profiles-dir .
