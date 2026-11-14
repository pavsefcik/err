# err v0.601.0 — dev tasks. The tool itself needs no build step.

VERSION := $(shell cat VERSION 2>/dev/null | tr -d '[:space:]')

.PHONY: test test-shell test-py lint install clean-pyc

test: test-shell test-py

# Dispatch, hooks, noglob guard — stubs both engines, no network, no models.
test-shell:
	@echo "== dispatch =="
	@zsh tests/test_dispatch.zsh

# err.py: explain/ask/sessions against a mock OpenAI server, no `fm` needed.
test-py:
	@echo "== err.py =="
	@python3 tests/test_err.py

lint:
	@zsh -n err-launcher.zsh && echo "err-launcher.zsh ok"
	@zsh -n err-models.zsh && echo "err-models.zsh ok"
	@zsh -n lib/err-helpers.zsh && echo "err-helpers.zsh ok"
	@python3 -m py_compile err.py && echo "err.py ok"

install:
	@sh install.sh

clean-pyc:
	@find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -name '*.pyc' -delete 2>/dev/null || true
