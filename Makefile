.PHONY: help lint lint-shell lint-docker lint-yaml test test-all check build clean install hooks page version

# Version derived from doc/CHANGELOG.md — single source of truth
VERSION := $(shell grep -m1 '^## [0-9]' doc/CHANGELOG.md 2>/dev/null | awk '{print $$2}' || echo "0.0.0")

# Shell files to lint
SHELL_SRC := cli/carranca cli/config.sh cli/diff.sh cli/init.sh cli/kill.sh cli/log.sh cli/run.sh cli/status.sh \
             cli/lib/common.sh cli/lib/config.sh cli/lib/env.sh cli/lib/identity.sh cli/lib/lifecycle.sh \
             cli/lib/log.sh cli/lib/orchestrator.sh cli/lib/runtime.sh cli/lib/session.sh cli/lib/timeline.sh \
             cli/lib/workspace.sh
SHELL_RUNTIME := runtime/config-runner.sh runtime/logger.sh runtime/network-setup.sh runtime/observer.sh \
                 runtime/shell-wrapper.sh runtime/lib/json.sh runtime/lib/strace-parser.sh
SHELL_TESTS := $(wildcard tests/unit/*.sh) $(wildcard tests/integration/*.sh) $(wildcard tests/failure/*.sh) tests/run_tests.sh
SHELL_HOOKS := .githooks/pre-commit .githooks/update-badges.sh .githooks/build-doc-page.sh
SHELL_ALL := $(SHELL_SRC) $(SHELL_RUNTIME) $(SHELL_TESTS) $(SHELL_HOOKS)

# Containerfiles to lint
CONTAINERFILES := runtime/Containerfile.logger templates/Containerfile templates/agents/claude.containerfile \
                  templates/agents/codex.containerfile templates/agents/opencode.containerfile

# YAML files to lint
YAML_FILES := templates/carranca.yml.tmpl

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

version: ## Print current version from doc/CHANGELOG.md
	@echo $(VERSION)

lint: lint-shell lint-docker lint-yaml ## Run all linters

lint-shell: ## Lint all bash scripts with shellcheck
	@echo "=== shellcheck ==="
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S error $(SHELL_ALL); \
		echo "shellcheck: OK ($(words $(SHELL_ALL)) files)"; \
	else \
		echo "shellcheck: SKIPPED (not installed)"; \
	fi

lint-docker: ## Lint Containerfiles with hadolint
	@echo "=== hadolint ==="
	@if command -v hadolint >/dev/null 2>&1; then \
		for f in $(CONTAINERFILES); do hadolint $$f; done; \
		echo "hadolint: OK ($(words $(CONTAINERFILES)) files)"; \
	else \
		echo "hadolint: SKIPPED (not installed — install from https://github.com/hadolint/hadolint)"; \
	fi

lint-yaml: ## Lint YAML files with yamllint
	@echo "=== yamllint ==="
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint $(YAML_FILES); \
		echo "yamllint: OK ($(words $(YAML_FILES)) files)"; \
	else \
		echo "yamllint: SKIPPED (not installed — pip install yamllint)"; \
	fi

test: ## Run unit tests (fast, no Docker)
	@echo "=== unit tests ==="
	@for f in tests/unit/test_*.sh; do bash "$$f" || exit 1; done

test-all: ## Run all tests (unit + integration + failure, requires Docker or Podman)
	@bash tests/run_tests.sh

check: lint test ## Run lint + unit tests (used by pre-commit hook)
	@echo ""
	@echo "=== All checks passed ==="

build: ## Build logger image
	@RUNTIME=$$(command -v podman 2>/dev/null || command -v docker 2>/dev/null) && \
	echo "Building carranca logger image ($$RUNTIME)..." && \
	$$RUNTIME build -t carranca-logger -f runtime/Containerfile.logger runtime/

clean: ## Remove carranca container images
	@RUNTIME=$$(command -v podman 2>/dev/null || command -v docker 2>/dev/null) && \
	echo "Cleaning ($$RUNTIME)..." && \
	$$RUNTIME images --filter "reference=carranca-*" -q | xargs -r $$RUNTIME rmi 2>/dev/null || true && \
	echo "Done"

install: ## Install carranca CLI (symlink to ~/.local/bin/)
	@mkdir -p ~/.local/bin
	@ln -sf $(CURDIR)/cli/carranca ~/.local/bin/carranca
	@chmod +x cli/carranca
	@echo "Installed: ~/.local/bin/carranca → $(CURDIR)/cli/carranca"
	@echo "Make sure ~/.local/bin is in your PATH"

hooks: ## Set up git hooks
	@git config core.hooksPath .githooks
	@chmod +x .githooks/*
	@echo "Git hooks configured: .githooks/"

page: ## Build doc/page/index.html with embedded docs
	@bash .githooks/build-doc-page.sh
