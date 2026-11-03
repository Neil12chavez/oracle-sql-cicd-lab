# Pipeline local — Oracle SQL

Documentación del pipeline local para desplegar cambios SQL en Oracle como si fuera CI/CD.

## Objetivo

Demostrar un flujo reproducible de despliegue de migraciones SQL:

```
preflight → reset → up → wait → lint → check
          → package (artefacto + checksum)
          → deploy (verificar checksum, extraer, aplicar)
          → verify
          → (rollback si falla)
```

Se despliega un **artefacto inmutable** y se valida contra una **BD limpia**.

## Stack

- Oracle Database Free 26ai — `gvenzl/oracle-free:23.26.3-slim`
- SQLcl 26.3 (pineado por digest)
- Docker Compose
- GNU Make
- sqlfluff (lint estático, dialecto Oracle)

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
   ./db (bind mount → init scripts)
```

## Targets del Makefile

| Target | Qué hace |
|---|---|
| `help` | Lista los targets. |
| `preflight` | Valida `.env`, `docker compose config` y estado de git. |
| `checkout` | Muestra estado de git (rama, último commit). |
| `lint` | `sqlfluff parse --dialect oracle` sobre `migrations/`. |
| `up` | `docker compose up -d --wait`. |
| `wait` | Espera a que `oracle-db` esté `healthy`. |
| `check` | Prueba de conexión (`SELECT 1 FROM dual`). |
| `package` | Crea `artifact/sql-<version>.tar.gz` + `.sha256`. |
| `deploy` | Verifica checksum, extrae en `.deploy/` y aplica con fail-fast. |
| `verify` | Comprueba que `SALARY` existe (PL/SQL con `RAISE_APPLICATION_ERROR`). |
| `rollback` | `down -v` + `up` (vuelve al baseline de la init). |
| `reset` | Alias de `rollback`. |
| `down` | `docker compose down` (conserva volumen). |
| `clean` | Borra `artifact/` y `.deploy/`. |
| `ci-local` | Pipeline completo; hace rollback automático si falla. |

Notas:
- `VERSION ?= 1.1` define el nombre del artefacto.
- `.SILENT: check deploy verify` evita que `make` imprima las recetas que contienen
  la cadena `CONNECT` (protección de credenciales en logs).

## Artefacto

- Ruta: `artifact/sql-1.1.tar.gz`.
- Checksum: `artifact/sql-1.1.tar.gz.sha256`.
- Contenido: `migrations/*.sql`.
- No se versiona en git (`.gitignore` ignora `artifact/`).

## Matriz de fallos (resultados reales)

| Test | Comando | Exit | Resultado |
|---|---|---|---|
| T1 — SQL inválido | `make ci-local` con `migrations/V9.9__bad.sql` | 2 | Falló en **deploy** (`ORA-00931`); `lint` no lo detectó; rollback OK |
| T2 — Checksum alterado | `make deploy` con artefacto corrupto | 2 | `sha256sum: FAILED`; no aplica nada |
| T3 — Artefacto ausente | `make deploy` sin artefacto | 2 | Falla por checksum/artefacto inexistente |
| T4 — Verify incompleto | `make verify` sobre baseline | 2 | `ORA-20001: SALARY missing` |
| T5 — Corrida final | `make ci-local` | 0 | `CI LOCAL OK`, 3 filas con `SALARY` |

## Lecciones

- **El lint no es un parser estricto.** `sqlfluff parse` con dialecto Oracle
  puede aceptar SQL que Oracle rechaza (`ORA-00931`). Se usa como *best-effort*;
  la **validación real** es aplicar en BD limpia con fail-fast (`deploy`).
- **`deploy` no es atómico.** Si un archivo posterior falla, los anteriores ya se
  aplicaron (DDL hace commit). El `rollback` recrea la BD desde el baseline.
  En producción se requeriría backup/snapshot y estrategia de rollback.
- **`slim` arranca rápido.** Los logs muestran la descompresión de datafiles al
  iniciar (~10–20 s en este equipo); no es necesario `faststart` para CI, y se
  ahorran ~3.6 GB de disco frente a `slim-faststart`.
- **Protección de secretos.** Las recetas que construyen `CONNECT` están en
  `.SILENT` para no imprimir credenciales. En CI se deben usar GitHub Secrets y
  el enmascarado de logs.

## Cómo ejecutar

```bash
cd ~/projects
make help
make ci-local
```

Verificar datos:

```bash
set -a; . ./.env; set +a
printf "CONNECT %s/%s@%s:%s/%s\nSELECT * FROM employees ORDER BY id;\nEXIT\n" \
  "$APP_USER" "$APP_USER_PASSWORD" "$DB_HOST" "$DB_PORT" "$DB_SERVICE" \
  | docker compose exec -T sqlcl sql /nolog
```

## Decisiones de diseño

- **Rollback al baseline** (recrear BD) en lugar de desplegar un artefacto
  anterior. Simple y suficiente para este laboratorio.
- **Versión manual** (`VERSION ?= 1.1`) en lugar de derivarla del nombre del archivo.
- **Deploy desde el artefacto**: se extrae en `.deploy/` (dentro del proyecto)
  para que el contenedor lo vea en `/workspace`.
- **Lint best-effort**: el gate real es `deploy` en limpio.

## Pendiente (evolución)

- Escaneo de secretos (`gitleaks`) y de imagen (`trivy`).
- Pin de la imagen de `sqlfluff`.
- Workflow de GitHub Actions que invoque `make ci-local`.
- Rollback a artefacto anterior (en lugar de recrear el baseline).
