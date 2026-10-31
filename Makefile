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

-include .env
export
DB_CONNECT := $(DB_HOST):$(DB_PORT)/$(DB_SERVICE)

.PHONY: help preflight checkout lint up wait check package deploy verify rollback reset down clean ci-local

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

preflight:
	set -e
	test -f .env || { echo "Falta .env"; exit 1; }
	$(COMPOSE) config --quiet
	@echo "preflight OK (git: $$(git branch --show-current))"

checkout:
	git status --porcelain
	git log -1 --oneline

lint:
	docker run --rm -v "$(CURDIR)/$(MIGRATIONS):/sql" sqlfluff/sqlfluff \
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