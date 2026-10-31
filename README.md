# Oracle SQL CI/CD Lab

Laboratorio local para **desplegar cambios SQL en Oracle como si fuera un pipeline CI/CD**,
usando Docker Compose y SQLcl. El objetivo es aprender el flujo
`checkout → validar → conectar → aplicar → verificar`, con artefactos y rollback.

## Stack

- **Oracle Database Free 26ai** — imagen `gvenzl/oracle-free:23.26.3-slim`
- **SQLcl 26.3** — cliente Oracle (pineado por digest)
- **Docker Compose** — infraestructura local
- **GNU Make** — orquestador del pipeline local
- **Git** — control de versiones

## Arquitectura

```
┌────────────────────────────────────────┐
│ docker compose (red interna)           │
│                                        │
│   oracle-db  ◄── oracle-db:1521 ─── sqlcl
│   /opt/oracle/oradata                  │
│        ▲                               │
│        │ volumen oracle-data           │
└────────┼───────────────────────────────┘
         │
   ./db (bind mount → scripts de init)
```

- `oracle-db`: base de datos; publica **solo** `127.0.0.1:1521`.
- `sqlcl`: cliente para ejecutar SQL y el pipeline.
- `oracle-data`: volumen persistente de datos de Oracle.
- `./db`: scripts de inicialización (se ejecutan al crear la BD).

---

## Fase 0 — Completada

Base reproducible y segura: repo, secretos fuera del código y compose limpio.

| Cambio | Detalle |
|---|---|
| **Repositorio git** | Inicializado en rama `main`; primer commit `chore(fase0)`. |
| **`.gitignore`** | Ignora `.env`, `dist/`, `artifact/`, `*.zip`, `*.tgz`, logs y basura de SO/editor. |
| **`.gitattributes`** | Fuerza LF (`* text=auto eol=lf`) para evitar CRLF en WSL/Linux. |
| **`.env` / `.env.example`** | Credenciales fuera del código. `.env` ignorado y con permisos `600`; `.env.example` versionado con placeholders. |
| **`docker-compose.yml`** | Sin `version:` (obsoleto); imágenes por variable; SQLcl pineado por digest; puerto `127.0.0.1:1521`; volumen `oracle-data`; `healthcheck` ajustado a `retries: 30` y `start_period: 180s`. |
| **Imagen Oracle** | Cambiada de `slim-faststart` (6.46 GB) a `slim` (2.84 GB en disco); se liberó ~4 GB. |
| **Validación** | `docker compose config --quiet` sin warnings. |

### Evidencia

```bash
git log --oneline
docker compose config --quiet && echo "COMPOSE OK"
docker images gvenzl/oracle-free
```

Salida esperada:

```
45caa42 chore(fase0): repo, secretos y compose reproducible
COMPOSE OK
gvenzl/oracle-free   23.26.3-slim   ...   2.84GB   848MB
```

### ¿Por qué `slim` y no `faststart`?

- `slim` (~809 MB comprimido): imagen ligera; el **primer arranque es lento** porque crea la BD.
- `*-faststart` (~6.46 GB en disco): arranque rápido, pensada para **CI efímero** (se crea y destruye la BD).
- **Decisión:** `slim` + volumen persistente en local. El coste de creación se paga **una sola vez**.
- Para CI (cuando se añada Actions) se puede usar `slim-faststart` solo en el job, vía `ORACLE_IMAGE`.

---

## Estado actual

- **Fase 0:** completada.
- **Fase 1 (en progreso):** init de BD con tabla `employees` + seed.
  - `db/01_schema.sql` eliminado (el usuario lo crea la imagen con `APP_USER`/`APP_USER_PASSWORD`).
  - Pendiente: calificar la tabla como `app_user.employees` y completar `db/03_seed.sql`.

## Inicio rápido

```bash
cd ~/projects
cp .env.example .env     # solo la primera vez; ajusta credenciales
docker compose up -d --wait
docker compose ps
```

> El primer arranque con `slim` puede tardar varios minutos (crea la base de datos).
> Si `--wait` se queda corto: `docker compose up -d` y revisa `docker compose logs -f oracle-db`.

## Acceso a la base de datos

Desde WSL, dentro del contenedor `sqlcl`:

```bash
docker compose exec -T sqlcl sql /nolog
```

```sql
CONNECT app_user/AppPassword123@oracle-db:1521/FREEPDB1
SELECT table_name FROM user_tables;
EXIT
```

> Importante: dentro de `sqlcl` se usa **`oracle-db`**, no `localhost`
> (`localhost` apunta al propio contenedor `sqlcl` y da `ORA-12541`).

Desde Windows/GUI: host `localhost`, puerto `1521`, servicio `FREEPDB1`.

## Variables de entorno

| Variable | Descripción |
|---|---|
| `ORACLE_IMAGE` | Imagen de Oracle (`gvenzl/oracle-free:23.26.3-slim`) |
| `SQLCL_IMAGE` | Imagen de SQLcl (pineada por digest) |
| `ORACLE_PASSWORD` | Password de `SYS`/`SYSTEM` |
| `APP_USER` | Usuario de la aplicación (`app_user`) |
| `APP_USER_PASSWORD` | Password del usuario de la aplicación |
| `DB_HOST` | Host interno (`oracle-db`) |
| `DB_PORT` | Puerto (`1521`) |
| `DB_SERVICE` | Servicio (`FREEPDB1`) |

> Nunca subas `.env` al repositorio. Usa `.env.example` como plantilla.

---

## Pipeline (diseño)

Pipeline local con Makefile, basado en bloques:

1. **Preflight** — repo limpio, compose válido, secretos fuera del código, imágenes pineadas.
2. **Checkout** — rama/commit correcto.
3. **Lint** — validación estática de sintaxis SQL (`sqlfluff`, dialecto Oracle).
4. **Connect** — levantar BD limpia, esperar `healthy` y probar conexión.
5. **Package** — artefacto `tar.gz` + `sha256` (build).
6. **Deploy** — verificar checksum, extraer y aplicar SQL con *fail-fast*.
7. **Verify** — comprobar esquema y datos.
8. **Rollback** — volver al baseline si la verificación falla.

Targets previstos:

```
make up | down | reset
make preflight | lint | check
make package | deploy | verify | rollback
make ci-local
```

Artefacto: `artifact/sql-<version>.tar.gz` + `.sha256` (no se versiona en git).

## Estructura (objetivo)

```
.
├── docker-compose.yml
├── .env / .env.example
├── Makefile
├── db/                 # bootstrap al crear la BD
│   ├── 02_table.sql
│   └── 03_seed.sql
├── migrations/         # cambios versionados (los aplica el pipeline)
│   └── V1.1__add_column.sql
├── artifact/           # artefactos generados (ignorado)
└── docs/pipeline.md
```

## Buenas prácticas aplicadas

- Secretos fuera del código (`.env` + `.env.example`).
- Imágenes pineadas por digest.
- Puerto publicado solo en `127.0.0.1`.
- Datos persistidos en volumen (`oracle-data`).
- `healthcheck` tolerante al primer arranque de `slim`.
- *Fail-fast* al aplicar SQL.
- Verificación posterior al deploy.
- Rollback explícito.
- Lint de SQL antes de conectar.
- Artefactos con checksum.

## Roadmap

- [x] **Fase 0** — repo, secretos y compose reproducible
- [ ] **Fase 1** — init con tabla `employees` + seed
- [ ] **Fase 2** — validar bloques a mano
- [ ] **Fase 3** — pipeline en Makefile
- [ ] **Fase 4** — pruebas de fallo/rollback
- [ ] **Fase 5** — documentación y DevSecOps básico
- [ ] (Después) GitHub Actions como capa fina

## Troubleshooting

| Error | Causa | Solución |
|---|---|---|
| `ORA-12541` | Se usó `localhost` dentro de `sqlcl` | Usar `oracle-db:1521` |
| `ORA-01920` | Usuario creado dos veces | No crear `app_user` en `db/`; lo crea la imagen |
| `permission denied ... docker.sock` | Sesión sin grupo `docker` | `newgrp docker` o reiniciar WSL (`wsl --shutdown`) |
| Contenedor `unhealthy` al inicio | `slim` tarda en crear la BD | Esperar y revisar `docker compose logs -f oracle-db` |
| `make: command not found` | `make` no instalado | `sudo apt install make` |

---

## Notas de aprendizaje

- **`faststart`** trae los datafiles ya expandidos: arranca rápido pero pesa mucho (6.46 GB en disco).
- En un contenedor, `localhost` es el propio contenedor; entre servicios se usa el **nombre de servicio** (`oracle-db`).
- `.gitignore` ignora archivos; `.gitattributes` define atributos como fin de línea (no se usa para secretos).
- Un **artefacto** es la salida inmutable y versionada del build; se despliega lo mismo que se validó.
