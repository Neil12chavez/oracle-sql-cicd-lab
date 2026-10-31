ALTER SESSION SET CONTAINER = FREEPDB1;

INSERT INTO app_user.employees (name) VALUES ('Ana');
INSERT INTO app_user.employees (name) VALUES ('Luis');
INSERT INTO app_user.employees (name) VALUES ('Maria');
COMMIT;