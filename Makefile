# err v0.602.0 — dev tasks. The tool itself needs no build step.

VERSION := $(shell cat VERSION 2>/dev/null | tr -d '[:space:]')

.PHONY: test test-shell test-py test-smoke test-menu lint install clean-pyc

test: test-shell test-py test-menu test-smoke

# Dispatch, hooks, noglob guard — stubs both engines, no network, no models.
test-shell:
	@echo "== dispatch =="
	@zsh tests/test_dispatch.zsh

# err.py: explain/ask/sessions against a mock OpenAI server, no `fm` needed.
test-py:
	@echo "== err.py =="
	@python3 tests/test_err.py
	@python3 tests/test_pty_proxy.py

# Menus: the real picker code (rows, cursor, cancel, choice), no toolkit.
test-menu:
	@echo "== menus =="
	@zsh tests/menu.zsh

# End to end: real launcher + err.py + engine dispatch, isolated state/conf.
test-smoke:
	@echo "== smoke =="
	@zsh tests/smoke.zsh

lint:
	@zsh -n err-launcher.zsh && echo "err-launcher.zsh ok"
	@zsh -n lib/err-pty-startup.zsh && echo "err-pty-startup.zsh ok"
	@zsh -n err-models.zsh && echo "err-models.zsh ok"
	@zsh -n lib/err-helpers.zsh && echo "err-helpers.zsh ok"
	@sh -n install.sh && echo "install.sh ok"
	@python3 -m py_compile err.py lib/err-pty-proxy.py tests/test_pty_proxy.py && echo "python ok"

install:
	@sh install.sh

clean-pyc:
	@find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -name '*.pyc' -delete 2>/dev/null || true
