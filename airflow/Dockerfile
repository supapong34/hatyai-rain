FROM apache/airflow:3.3.2-python3.12

# ติดตั้ง library ของโปรเจกต์ โดยระบุ Airflow เวอร์ชันเดิมไว้ด้วย กัน pip อัปเกรด Airflow โดยไม่ตั้งใจ
COPY requirements.txt /requirements.txt
RUN pip install --no-cache-dir "apache-airflow==3.3.2" -r /requirements.txt
