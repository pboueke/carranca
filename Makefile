.PHONY: help lint lint-shell lint-docker lint-yaml test test-all check build clean install hooks version

# Version derived from CHANGELOG.md — single source of truth
VERSION := $(shell grep -m1 '## \[' CHANGELOG.md 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/' || echo "0.0.0")

# Shell files to lint
SHELL_SRC := cli/carranca cli/init.sh cli/run.sh cli/lib/common.sh cli/lib/config.sh cli/lib/identity.sh
SHELL_RUNTIME := runtime/shell-wrapper.sh runtime/logger.sh
SHELL_TESTS := $(wildcard tests/unit/*.sh) $(wildcard tests/integration/*.sh) $(wildcard tests/failure/*.sh) tests/run_tests.sh
SHELL_HOOKS := .githooks/pre-commit .githooks/update-badges.sh
SHELL_ALL := $(SHELL_SRC) $(SHELL_RUNTIME) $(SHELL_TESTS) $(SHELL_HOOKS)

# Containerfiles to lint
CONTAINERFILES := runtime/Containerfile.logger templates/Containerfile

# YAML files to lint
YAML_FILES := templates/carranca.yml.tmpl

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

version: ## Print current version from CHANGELOG.md
	@echo $(VERSION)

lint: lint-shell lint-docker lint-yaml ## Run all linters

lint-shell: ## Lint all bash scripts with shellcheck
	@echo "=== shellcheck ==="
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SHELL_ALL); \
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

test-all: ## Run all tests (unit + integration + failure, requires Docker)
	@bash tests/run_tests.sh

check: lint test ## Run lint + unit tests (used by pre-commit hook)
	@echo ""
	@echo "=== All checks passed ==="

build: ## Build logger image
	@echo "Building carranca logger image..."
	@docker build -t carranca-logger -f runtime/Containerfile.logger runtime/

clean: ## Remove carranca Docker images
	@echo "Cleaning..."
	@docker images --filter "reference=carranca-*" -q | xargs -r docker rmi 2>/dev/null || true
	@echo "Done"

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
