FROM apache/airflow:3.3.2-python3.12

# library ระบบที่ driver mssql-python (ใช้โดย dbt) ต้องการ
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends libltdl7 libkrb5-3 libgssapi-krb5-2 \
 && rm -rf /var/lib/apt/lists/*
USER airflow

# library ของโปรเจกต์ โดยระบุ Airflow เวอร์ชันเดิม กัน pip อัปเกรด Airflow โดยไม่ตั้งใจ
COPY requirements.txt /requirements.txt
RUN pip install --no-cache-dir "apache-airflow==3.3.2" -r /requirements.txt

# dbt แยก virtualenv ของตัวเอง เพราะ dependency ของ dbt กับ Airflow มักชนกัน
RUN python -m venv /home/airflow/dbt_venv \
 && PIP_USER=false /home/airflow/dbt_venv/bin/pip install --no-cache-dir "dbt-sqlserver[mssql]==1.12.1"
