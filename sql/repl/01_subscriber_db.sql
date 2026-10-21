/* รันบน: mssql2 (subscriber)
   เตรียมฐานข้อมูลปลายทางและ schema ให้ snapshot สร้างตารางลงได้ */
IF DB_ID('rain_dw') IS NULL CREATE DATABASE rain_dw;
GO
USE rain_dw;
GO
IF SCHEMA_ID('raw')  IS NULL EXEC('CREATE SCHEMA raw');
IF SCHEMA_ID('meta') IS NULL EXEC('CREATE SCHEMA meta');
GO
PRINT 'subscriber database is ready';
