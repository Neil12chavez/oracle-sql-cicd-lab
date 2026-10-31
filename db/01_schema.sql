-- Se ejecuta como SYSDBA al arrancar el contenedor
ALTER SESSION SET CONTAINER = FREEPDB1;  --vamos a trabajar dentro de FREEPDB1
CREATE USER app_user IDENTIFIED BY "AppPassword123";    -- Crea una cuenta llamada APP_USER, con su contraseña
GRANT CONNECT, RESOURCE, UNLIMITED TABLESPACE TO app_user;  -- nos indica que nos conectemos, crear objetos y usar espacio para guardarlos