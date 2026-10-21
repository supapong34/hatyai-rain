#!/usr/bin/env bash
# รันไฟล์ SQL ใน container ที่ระบุ พร้อมส่งรหัส sa เป็น sqlcmd variable
#   ./sqlrun.sh rain_mssql  sql/repl/02_distributor.sql
#   ./sqlrun.sh rain_mssql2 sql/repl/01_subscriber_db.sql
set -euo pipefail
container="$1"; file="${2#sql/}"
docker exec "$container" bash -c \
  '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -v SA_PASSWORD="$MSSQL_SA_PASSWORD" -i "/sql/'"$file"'"'
