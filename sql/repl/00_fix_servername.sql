/* รันบน: mssql (publisher)
   container เดิมถูกสร้างตอนยังไม่ได้ตั้ง hostname ชื่อ server ภายใน (@@SERVERNAME)
   จึงเป็นเลข container เก่า replication ต้องการให้ตรงกับ hostname ปัจจุบัน
   รันเสร็จต้อง restart container: docker restart rain_mssql */
DECLARE @old sysname = @@SERVERNAME;
DECLARE @new sysname = CAST(SERVERPROPERTY('MachineName') AS sysname);   -- hostname ปัจจุบัน = mssql

IF @old <> @new
BEGIN
    EXEC sp_dropserver @old;
    EXEC sp_addserver @new, 'local';
    PRINT CONCAT('server name changed: ', @old, ' -> ', @new, ' (restart the container now)');
END
ELSE
    PRINT CONCAT('server name already correct: ', @new);
