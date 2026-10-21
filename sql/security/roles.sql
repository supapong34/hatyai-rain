/* =====================================================================
   Lab 1: Security - login, user, role และสิทธิ์ระดับ schema
   รันบน: mssql (localhost,1433) ด้วย sa   |   รันซ้ำได้
   ก่อนรัน: เปลี่ยน <ETL_PASSWORD> และ <ANALYST_PASSWORD> เป็นรหัสจริง
            (ห้ามมีชื่อ login อยู่ในรหัส ห้าม commit รหัสจริงขึ้น git)
   ===================================================================== */
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'etl_writer')
    CREATE LOGIN etl_writer WITH PASSWORD = '<ETL_PASSWORD>', CHECK_POLICY = ON;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'analyst_reader')
    CREATE LOGIN analyst_reader WITH PASSWORD = '<ANALYST_PASSWORD>', CHECK_POLICY = ON;
GO

USE rain_dw;
GO
IF USER_ID('etl_writer')     IS NULL CREATE USER etl_writer     FOR LOGIN etl_writer;
IF USER_ID('analyst_reader') IS NULL CREATE USER analyst_reader FOR LOGIN analyst_reader;
IF DATABASE_PRINCIPAL_ID('role_etl')     IS NULL CREATE ROLE role_etl;
IF DATABASE_PRINCIPAL_ID('role_analyst') IS NULL CREATE ROLE role_analyst;
GO

-- pipeline: อ่านเขียน raw/meta และสร้างตารางพัก _stg_* ใน raw ได้
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::raw  TO role_etl;
GRANT SELECT, INSERT, UPDATE         ON SCHEMA::meta TO role_etl;
GRANT CREATE TABLE TO role_etl;
GRANT ALTER ON SCHEMA::raw TO role_etl;

-- นักวิเคราะห์: อ่าน marts และ rpt เท่านั้น ห้ามเห็นข้อมูลดิบ
-- (ให้สิทธิ์ระดับ schema เพราะ dbt สร้างตาราง marts ใหม่ทุกรอบ)
GRANT SELECT ON SCHEMA::marts TO role_analyst;
GRANT SELECT ON SCHEMA::rpt   TO role_analyst;
DENY  SELECT ON SCHEMA::raw   TO role_analyst;

-- etl รัน procedure รายงานได้ โดยไม่ต้องมีสิทธิ์เขียนตาราง rpt (ownership chaining)
IF OBJECT_ID('rpt.usp_build_monthly_rain') IS NOT NULL
    GRANT EXECUTE ON OBJECT::rpt.usp_build_monthly_rain TO role_etl;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
               JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
               WHERE m.name = 'etl_writer')
    ALTER ROLE role_etl ADD MEMBER etl_writer;
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm
               JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
               WHERE m.name = 'analyst_reader')
    ALTER ROLE role_analyst ADD MEMBER analyst_reader;
GO

-- ตรวจสิทธิ์ทั้งหมด (ใช้ตอบ audit ว่าใครมีสิทธิ์อะไร)
SELECT pr.name AS principal, pe.state_desc, pe.permission_name, pe.class_desc,
       COALESCE(SCHEMA_NAME(pe.major_id), OBJECT_NAME(pe.major_id)) AS on_object
FROM sys.database_permissions pe
JOIN sys.database_principals pr ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name LIKE 'role_%'
ORDER BY pr.name, pe.permission_name;
