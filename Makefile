# --- Variables ---
PROJECT_NAME = mi-proyecto-db
DB_USER = app_user
DB_PASS = AppPassword123
DB_CONNECT = localhost:1521/FREEPDB1

# --- Comandos Principales ---

# Levanta el entorno (base de datos + SQLcl)
up:
	@echo "🚀 Levantando entorno Oracle 26ai y SQLcl..."
	docker-compose up -d
	@echo "✅ Entorno listo. La base de datos está en localhost:1521"

# Detiene y elimina los contenedores
down:
	@echo "🛑 Deteniendo entorno..."
	docker-compose down -v

# Inicializa un proyecto de SQLcl (solo la primera vez)
init-project:
	@echo "🔧 Inicializando proyecto SQLcl..."
	# Este comando se ejecuta DENTRO del contenedor de SQLcl
	docker-compose exec sqlcl sql /nolog <<-EOF
	CONNECT ${DB_USER}/${DB_PASS}@${DB_CONNECT}
	PROJECT INIT ${PROJECT_NAME}
	EXIT
	EOF
	@echo "✅ Proyecto '${PROJECT_NAME}' inicializado."

# Prepara y despliega una migración (simula el flujo de CI/CD)
deploy:
	@echo "📦 Preparando y desplegando migración..."
	# 1. Copiamos el script de migración al directorio 'next' que SQLcl espera.
	#    (En un flujo real, SQLcl exportaría los cambios del esquema de desarrollo)
	mkdir -p ${PROJECT_NAME}/next
	cp src/V1.1__add_column.sql ${PROJECT_NAME}/next/
	
	# 2. Ejecutamos el flujo de SQLcl Projects: stage -> release -> deploy
	docker-compose exec sqlcl sql /nolog <<-EOF
	CONNECT ${DB_USER}/${DB_PASS}@${DB_CONNECT}
	PROJECT STAGE
	PROJECT RELEASE -version 1.1
	PROJECT DEPLOY
	EXIT
	EOF
	@echo "✅ Migración desplegada."

# Verifica que el cambio se aplicó correctamente
verify:
	@echo "🔍 Verificando el estado del esquema..."
	docker-compose exec sqlcl sql /nolog <<-EOF
	CONNECT ${DB_USER}/${DB_PASS}@${DB_CONNECT}
	SELECT column_name, data_type FROM user_tab_columns WHERE table_name = 'EMPLOYEES';
	EXIT
	EOF
	@echo "✅ Verificación completada. Deberías ver la columna 'SALARY'."

# Flujo completo de validación
ci-local: up init-project deploy verify
	@echo "🎉 Flujo CI/CD local completado con éxito."

.PHONY: up down init-project deploy verify ci-local