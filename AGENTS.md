# AGENTS.md — working on err

`err` is two tools wearing one name:

1. **explain / ask** — `err`, `err <question>`, `errc <cmd>`, plus conversation
   sessions. Runs on the on-device Apple Foundation Model (`fm`), no API key.
2. **model manager** — `err run|switch|default|stop|chat|list|curated|download|
   remove|settings|info|cache|clean|endpoint|status|uninstall|tui`, carried over
   from marv-mlx, serving local MLX models behind an OpenAI-compatible endpoint
   on `:11500`.

Version lives in `VERSION` (`0.601.0`). `CONTRACT.md` is the authoritative
description of the seams between the three layers — read it before touching
dispatch, env vars, or session storage.

## Layout

| File | Role | Runs in |
|---|---|---|
| `err-launcher.zsh` | sourced by `~/.zshrc`; hooks, dispatch, `err`/`errc` | the user's interactive shell |
| `err.py` | explain / ask / sessions / backends, stdlib only | a child `python3` |
| `err-models.zsh` | the ported marv-mlx engine | a child `zsh` |
| `lib/err-helpers.zsh` | engine helpers (`_err_*`), sourced only by the engine | that child |
| `lib/err_repl.py` | the `err chat` REPL | a child `python3` |
| `lib/err_moe/` | streaming-MoE server for models too big for RAM | a child `python3` |
| `tests/` | `test_dispatch.zsh`, `test_err.py` + mock SSE server | CI / `make test` |
| `install.sh` | uv + gum + mlx-vlm, then wires the launcher into `~/.zshrc` | the user |

`err.conf` holds the explain/ask settings (prompts, `backend`, `port` for `fm`).
The model-launch settings are a separate file, `$ERR_STATE_DIR/config.zsh`,
written by `err settings`.

State: `ERR_STATE_DIR`, default `~/.cache/marv/mlx` — inherited from marv-mlx on
purpose so existing config, chats, logs and the APC cache keep working. It holds
`config.zsh`, `sessions/`, `chats/`, `logs/`, `apc/`, `run/` (per-shell scratch),
`default-model`, `last-model`, `curated-llms.md`. Weights live in the HF hub
cache, never there.

## Invariants — break these and the tool stops being err

1. **Never execute model output.** The model's suggested command goes to
   `_ERR_SUGGEST_FILE`; the launcher drops it into the prompt buffer with
   `print -z`. The human is the confirmation step. This is the line between err
   and the tool it replaced.
2. **`err.py` is stdlib-only and Python-3.9-clean.** It is invoked as bare
   `python3`, and that can be the CLT's 3.9. No new dependencies, no
   `match`, no `X | Y` annotations, no f-strings inside f-strings.
3. **Data on stdout, diagnostics on stderr, exit codes 0/1/2.** The `--json`
   shapes of `status`, `list`, `info`, `endpoint` and `curated` are consumed by
   the pi extension and other clients — do not reshape them, extend them.
4. **Reserved verbs win over free text.** `err run` is the model verb, never the
   question "run". Documented in the help text; do not "fix" it.
5. **The launcher must survive being sourced into someone else's shell.** No
   `set -e`, no `exit`, no clobbering a non-empty `RPROMPT`/`PROMPT`, no tty
   writes at source time, and it must work under `setopt nounset`.

## Gotchas that already bit us (do not re-learn them)

- **`noglob` breaks naive preexec guards.** `alias err='noglob err'` means the
  hook sees `noglob err …`. `_err_is_ours()` strips the prefix; anything that
  matches command lines must go through it, or `err` records itself as your
  last command.
- **`set -euo pipefail` + `source` of a missing file aborts the whole script on
  macOS's bash 3.2, even with `|| true`.** This is what killed the mang.sh
  installer silently. `install.sh` therefore uses `set -eu`, sources nothing
  unguarded, and prints which step failed.
- **`ERR_DEBUG` is `local ERR_DEBUG=false` in the engine,** so `[[ -n $ERR_DEBUG ]]`
  is always true. Test for truthiness (`!= (0|false|"")`), never for "is set".
- **Never use a fixed path under `/tmp`** for per-invocation state. All scratch
  files live in `$ERR_STATE_DIR/run/<name>.$$`; a shared `/tmp/err_stderr` let a
  stale stderr attach to a later explanation.
- **`APC_DISK_MAX_GB` is per model directory, not per store.** mlx-vlm bounds
  each `<model>_s4-<hash>/` separately, so N models cost N × cap (18 GiB on a
  5-model install). `_err_apc_sweep` bounds the total and runs before every
  launch; keep it there or the disk grows with every model you try.
- **Do not key sessions by PID.** macOS recycles pids; a fresh tab could inherit
  a dead tab's conversation. Sessions carry a uuid, and pid/tty are only
  informational.
- **Markers in menus must be one column wide.** `★` and friends are East Asian
  wide and shift every row under them; the default marker is ASCII `* ` with
  `  ` for everything else.
- **`_marv_mlx_` → `_err_` renaming produced `lib/err__moe`** (double underscore)
  because the pattern ate the boundary. Grep for `err__` if you rename again.

## Testing

```sh
make lint    # zsh -n on the three .zsh files, py_compile on err.py
make test    # test_dispatch.zsh (hooks + dispatch, stubs both engines)
             # test_err.py      (explain/ask/sessions against a mock SSE server)
```

Covered without a TTY, without `fm`, without models or network:
dispatch routing for every verb, the preexec guard, unquoted `?`, explain and
ask message construction, session round-trip, redaction, token accounting,
`resume` listing, `new` writing `_ERR_SESSION_ID_FILE`.

**Not covered automatically:** anything that needs a real terminal (the gum
menus, `err tui`, `err chat`) or real weights (`err run`). To exercise a menu
non-interactively, put a fake `gum` on `PATH` that dumps stdin and exits 1 — the
real picker code then runs and the rows are visible:

```sh
mkdir -p /tmp/fakebin && printf '#!/bin/sh\ncase "$1" in choose) cat >&2; exit 1;; *) exit 0;; esac\n' > /tmp/fakebin/gum
chmod +x /tmp/fakebin/gum
PATH=/tmp/fakebin:$PATH zsh ./err-models.zsh run
```

Manual smoke that does need the real model:

```sh
zsh -f -i    # then: source ./err-launcher.zsh
             # err what is a glob?      -> answer + suggested command
             # err and why does it matter?  -> turn 2, history included
             # err resume                -> session list
```

`err status` and `err run apple-fm` start `fm serve`; `err stop apple-fm` or
`pkill -f 'fm serve'` cleans up. The `fm` server has its own idle watchdog
(`err.conf` → `idle_timeout_minutes`).

## Release checklist

1. Bump `VERSION` (and `CHANGELOG.md`).
2. `make lint test`.
3. Check the update-check URL in `_err_check_update` points at this repo's
   `VERSION` on `main` (`raw.githubusercontent.com/pavsefcik/err/main/VERSION`).
4. Help text lives in **one** place: `_err_help()` in `err-launcher.zsh`. The
   README block must match it character for character — diff them.
5. `install.sh` must stay idempotent (re-runnable), must never duplicate the
   `~/.zshrc` line, and must not require Rust, Xcode CLT or Homebrew.

## Deliberately out of scope

- The **marv** harness (agent loop, tools, TUI) — a different tool, left where
  it was.
- The **marv-mlx pi extension** (`extensions/marv-mlx.ts`, `/marv-mlx-setup`,
  `/marv-mlx-sync`) — not ported. `err endpoint`/`err status` still expose what
  such an integration would need.
- The marv-mlx **chat-history TUI** — replaced by the session verbs
  (`new` / `clear` / `resume` / `delete`).
- Bash support in the launcher. `preexec`/`print -z`/`noglob` are zsh features;
  the bash branch in `err-launcher.zsh` is best-effort only.
