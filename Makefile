SHELL := /bin/bash
.ONESHELL:
.NOTPARALLEL:
.DEFAULT_GOAL := help

COMPOSE      := docker compose
MIGRATIONS   := migrations
ARTIFACT_DIR := artifact
VERSION      ?= 1.1
ARTIFACT     := $(ARTIFACT_DIR)/sql-$(VERSION).tar.gz
SQLCL        := $(COMPOSE) exec -T --user $$(id -u):$$(id -g) -e HOME=/tmp sqlcl
SQLFLUFF_IMAGE := sqlfluff/sqlfluff@sha256:8a408e8f236e922fc128e06d634c74f4c683394970c8ffc5d44100a341e3adf0
GITLEAKS_IMAGE := ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
TRIVY_IMAGE    := aquasec/trivy@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c

-include .env
export
DB_CONNECT := $(DB_HOST):$(DB_PORT)/$(DB_SERVICE)
ORACLE_SCAN_IMAGE := $(if $(ORACLE_IMAGE),$(ORACLE_IMAGE),gvenzl/oracle-free:23.26.3-slim)

.PHONY: help preflight checkout lint up wait check package deploy verify rollback reset down clean ci-local security security-secrets security-image security-history
.SILENT: check deploy verify

help:
	@echo "Targets:"
	@echo "  preflight  valida repo/compose/env"
	@echo "  checkout   estado de git"
	@echo "  lint       valida sintaxis SQL (sqlfluff)"
	@echo "  up/wait    levanta y espera healthy"
	@echo "  check      prueba de conexión"
	@echo "  package    crea artefacto + sha256"
	@echo "  deploy     verifica checksum, extrae y aplica"
	@echo "  verify     comprueba esquema/datos"
	@echo "  rollback   vuelve al baseline"
	@echo "  reset      down -v + up (BD limpia)"
	@echo "  ci-local   pipeline completo"
	@echo "  security   escaneo de secretos (tracked) + imagen (reporte)"
	@echo "  security-history  escaneo del historial (informativo)"

preflight:
	set -e
	test -f .env || { echo "Falta .env"; exit 1; }
	$(COMPOSE) config --quiet
	@echo "preflight OK (git: $$(git branch --show-current))"

checkout:
	git status --porcelain
	git log -1 --oneline

lint:
	docker run --rm -v "$(CURDIR)/$(MIGRATIONS):/sql" $(SQLFLUFF_IMAGE) \
	  parse --dialect oracle /sql >/dev/null
	@echo "lint OK"

up:
	$(COMPOSE) up -d --wait

wait:
	set -e
	cid=$$($(COMPOSE) ps -q oracle-db)
	for i in $$(seq 1 60); do
	  [ "$$(docker inspect -f '{{.State.Health.Status}}' $$cid)" = healthy ] && exit 0
	  sleep 5
	done
	echo "Timeout esperando healthy"; exit 1

check:
	printf 'CONNECT $(APP_USER)/$(APP_USER_PASSWORD)@$(DB_CONNECT)\nSELECT 1 FROM dual;\nEXIT\n' \
	  | $(SQLCL) sql /nolog

package:
	mkdir -p $(ARTIFACT_DIR)
	tar czf $(ARTIFACT) $(MIGRATIONS)
	sha256sum $(ARTIFACT) > $(ARTIFACT).sha256
	@echo "artefacto: $(ARTIFACT)"

deploy:
	set -e
	sha256sum -c $(ARTIFACT).sha256
	rm -rf .deploy && mkdir -p .deploy
	tar xzf $(ARTIFACT) -C .deploy
	{
	  echo "CONNECT $(APP_USER)/$(APP_USER_PASSWORD)@$(DB_CONNECT)"
	  echo "WHENEVER SQLERROR EXIT SQL.SQLCODE"
	  for f in .deploy/$(MIGRATIONS)/*.sql; do echo "@$$f"; done
	  echo "EXIT"
	} | $(SQLCL) sql /nolog

verify:
	set -e
	$(SQLCL) sql /nolog <<SQL
	CONNECT $(APP_USER)/$(APP_USER_PASSWORD)@$(DB_CONNECT)
	WHENEVER SQLERROR EXIT SQL.SQLCODE
	DECLARE v NUMBER;
	BEGIN
	  SELECT COUNT(*) INTO v FROM user_tab_columns
	   WHERE table_name='EMPLOYEES' AND column_name='SALARY';
	  IF v = 0 THEN RAISE_APPLICATION_ERROR(-20001, 'SALARY missing'); END IF;
	END;
	/
	SELECT COUNT(*) AS filas FROM employees;
	EXIT
	SQL

rollback:
	$(COMPOSE) down -v
	$(COMPOSE) up -d --wait

reset: rollback

down:
	$(COMPOSE) down

clean:
	rm -rf $(ARTIFACT_DIR) .deploy

ci-local:
	set -e
	trap 'echo "FALLÓ: rollback"; $(MAKE) rollback' ERR
	$(MAKE) preflight
	$(MAKE) reset
	$(MAKE) up
	$(MAKE) wait
	$(MAKE) lint
	$(MAKE) check
	$(MAKE) package
	$(MAKE) deploy
	$(MAKE) verify
	@echo "CI LOCAL OK"

security: security-secrets security-image

security-secrets:
	set -euo pipefail
	tmp=$$(mktemp -d)
	trap 'rm -rf "$$tmp"' EXIT
	git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$$tmp"
	docker run --rm -v "$$tmp:/repo:ro" $(GITLEAKS_IMAGE) \
	  detect --source /repo --no-git -v
	@echo "security-secrets OK"

security-image:
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock $(TRIVY_IMAGE) \
	  image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 0 $(ORACLE_SCAN_IMAGE)
	@echo "$(ORACLE_SCAN_IMAGE): reporte generado (no bloqueante)"

security-history:
	docker run --rm -v "$(CURDIR):/repo" $(GITLEAKS_IMAGE) \
	  detect --source /repo --log-opts="--all" -v