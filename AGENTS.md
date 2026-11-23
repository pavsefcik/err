# AGENTS.md — working on err

`err` is two tools wearing one name:

1. **explain / ask** — `err wtf`, `err "<question>"`, plus
   conversation sessions (`new` / `resume`). Bare `err`, `err -h` and `err help`
   open the interactive menu. Runs on the on-device Apple Foundation Model
   (`fm`), no API key.
2. **model manager** — `err run|swap|stop|list|info|download|remove|config|
   cleanup|uninstall|doctor` (plus hidden `version`/`ls`/`rm`), carried over
   from marv-mlx, serving local MLX models behind an OpenAI-compatible endpoint
   on `:11500`.

Version lives in `VERSION` (`0.603.0`). `CONTRACT.md` is the authoritative
description of the seams between the three layers — read it before touching
dispatch, env vars, or session storage.

## Layout

| File | Role | Runs in |
|---|---|---|
| `err-launcher.zsh` | sourced by `~/.zshrc`; hooks, dispatch, the menu entry point | the user's interactive shell |
| `err.py` | explain / ask / sessions / backends, stdlib only | a child `python3` |
| `err-models.zsh` | the ported marv-mlx engine | a child `zsh` |
| `lib/err-helpers.zsh` | engine helpers (`_err_*`), sourced only by the engine | that child |
| `lib/err_moe/` | streaming-MoE server for models too big for RAM | a child `python3` |
| `lib/err-pty-startup.zsh` | opt-in PTY bootstrap, sourced first from `~/.zshrc` | zsh startup |
| `lib/err-pty-proxy.py` | TTY relay and bounded OSC-delimited output capture | parent terminal |
| `tests/` | dispatch, Python, PTY proxy, mock SSE and smoke suites | CI / `make test` |
| `install.sh` | uv + mlx-vlm, then wires startup hook and launcher into `~/.zshrc` | the user |

`err.conf` is the one config file, `$ERR_STATE_DIR/err.conf` (seeded from the
repo template, opened by `err config`). Thinking is its first line.

State: `ERR_STATE_DIR`, default `~/.cache/err`. **`~/.cache/marv` belongs to the
marv harness** — never write err's state there; the launcher's one-time migration
only *reads* it. It holds
`err.conf`, `sessions/`, `logs/`, `apc/`, `run/` (per-shell scratch),
`last-model` (the default model), `err-curator.md` (the curated catalog). Weights
live in the HF hub cache, never there.

**One config file.** `$ERR_STATE_DIR/err.conf` — flat `key = value`, one per
line, comments on their own line only (err.py keeps the whole value after `=`,
so `port = 8080  # x` breaks it). Python and zsh read the same file. Repeatable
`server_flag` lines are the only multi-value key.

## Invariants — break these and the tool stops being err

1. **Never execute model output, and don't pre-fill either.** The model's
   suggested command goes to `_ERR_SUGGEST_FILE`; the launcher consumes it
   according to `err.conf` → `suggest`: `history` (default) appends it to shell
   history with `print -s` so ↑ recalls it, `ask` uses `print -z` to drop it in
   the buffer, `off` discards it. ↑ *is* the confirmation step. This is the line between err
   and the tool it replaced.
2. **`err.py` is stdlib-only and Python-3.9-clean.** It is invoked as bare
   `python3`, and that can be the CLT's 3.9. No new dependencies, no
   `match`, no `X | Y` annotations, no f-strings inside f-strings.
3. **Data on stdout, diagnostics on stderr, exit codes 0/1/2.** The `--json`
   shapes of `info` and `list` are consumed by the pi extension and other
   clients — do not reshape them, extend them. err's own action lines
   (`arr // …`) are human-facing: they go to stdout, and the colour is dropped
   when stdout is not a terminal.
4. **`err` with no arguments opens the menu, and so do `err -h` and
   `err help`.** The engine owns the rows and the pickers (`_err_help_menu` in
   err-models.zsh); it returns `<verb>\t<rest>` and the launcher re-dispatches
   it through `err`, never `eval`, so the menu cannot drift from the typed
   command. Off a terminal the engine prints the rows instead of a picker
   (`_err_help_rows`) — that is what scripts and the tests see. The question,
   `wtf` and `help` lines are shown in the header (`_err_help_header`) but are
   not pickable: the cursor's first row is `err new` and cannot move above it.
5. **Reserved verbs win over free text.** `err run` is the model verb, never the
   question "run". Documented in the help text; do not "fix" it.
6. **The launcher must survive being sourced into someone else's shell.** No
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
- **One model at a time.** A second model replaces the first. Ports stay a
  contract — `run`/`swap` own `:11500`.
- **Every server err starts gets shut down again.** `err.py:ensure_running`
  (fm) and the engine's `_err_arm_watchdog` (the MLX model on :11500) arm the
  idle watchdog via `python3 err.py --watchdog <pid> [port]`, and
  `err.py --watchdog-run` is that detached loop. Heartbeats are per server:
  `$ERR_STATE_DIR/fm_heartbeat` for fm, `mlx_heartbeat-<port>` for MLX. Never
  arm a watchdog
  from a read-only query (`err info` is polled by clients — it would keep
  every model awake forever).
- **Two system prompts, and they are opposite on purpose.** The question prompt
  asks for a fenced example (that block is what feeds `_ERR_SUGGEST_FILE`); the
  explain prompt forbids one (`err wtf` must never put a command in history).
  Both live only in `err.conf` (`explain_system_prompt`,
  `question_system_prompt`; `err config` edits them, `err reset` restores the
  shipped ones). There is no built-in copy in `err.py`: a missing or empty key
  makes err refuse to answer. `err doctor` reads them via
  `err.py --prompt explain|question` (`origin<TAB>text`) — if you add a prompt,
  wire it into that flag, not into a second parser in zsh.
- **Never capture by tee/redirection.** A shell hook cannot tee stdout while
  preserving fd 1 as a TTY; that breaks TUIs (pi, claude, vim, etc.). The
  opt-in `capture = pty` mode is bootstrapped by `lib/err-pty-startup.zsh`
  before other `.zshrc` integrations; it starts `lib/err-pty-proxy.py` around
  the interactive shell. Tokenized OSC markers delimit command output; test
  TTY semantics and marker splitting whenever the proxy changes. Legacy
  `capture = on` is ignored.
- **Watchdog pids must be the listener, not `$!`.** `mlx_vlm.server` is a uv
  shim that spawns the real server as a child, so SIGTERM to `$!` leaves the
  model (and its RAM) behind. `_err_arm_watchdog` resolves the pid with
  `lsof -iTCP:<port> -sTCP:LISTEN -t` and falls back to the launched pid. The
  engine's fm path had the same shape of bug harder: it passed an unset `pid`,
  so the watchdog was never armed at all.
- **Quotes in an associative-array subscript are part of the key.** `M["$k"]=v`
  stores the key `"v"` *with quotes*; `${M[$k]}` then misses. This silently
  broke **every** menu selection for a while (rows rendered, choice discarded,
  engine returned 1 with no message) — `_ERR_PICK_MAP[$label]=` must stay
  unquoted. Lookup position is fine either way.
- **`$var[` is an array subscript in zsh.** `grep -E "^\s*$key[[:space:]]*="` is
  parsed as `$key[...]` and dies with "bad output format specification". Write
  `${key}` whenever a variable is followed by `[`.
- **`model_id` in err.conf is an fm value (`system` / `pcc`), never an MLX id.**
  Sending it to the :11500 server makes mlx-vlm try to download a repo named
  `system`. `mlx_model_id()` resolves the served model from `last-model` /
  `last-model`, so the manager and the explain layer cannot drift again.
- **Ports are a contract.** `err run`/`err swap` own `:11500` (every client,
  including err's own `backend = mlx`, reads that). `status --json` and
  `endpoint` were folded into `err info` / `info --json`.
- **The chosen model must reach the explain layer.** `err default` / `err switch`
  record `$ERR_STATE_DIR/last-model` *and* rewrite `backend` in `err.conf`
  (`_err_point_backend_at`). Writing only the file leaves `err` answering from
  `fm` while the menu shows another model as default — that was a real bug.
  There is no `err default` any more: `last-model` *is* the default, and
  `run`/`swap` write it.
- **Starting :11500 is err.py's job.** When `backend = mlx` and the server is
  down, err.py runs the hidden engine verb `ensure <model>` (stop every err
  server, start the chosen model) instead of printing "start it with `err run`".
  The engine's stdout is redirected to **stderr** in that call — stdout is the
  answer, and mixing them breaks `err "<q>" | pbcopy`. `ensure` also *waits* for a
  model that is already loading instead of killing it: relaunching costs the
  whole load again. `mlx_autostart = off` is the escape hatch.
- **`APC_DISK_MAX_GB` is per model directory, not per store.** mlx-vlm bounds
  each `<model>_s4-<hash>/` separately, so N models cost N × cap. `_err_apc_sweep`
  also expires checkpoint files untouched for `apc_max_age_days` (7) and bounds
  the TOTAL by `ERR_APC_TOTAL_GB`; it runs before every launch and after every
  stop. Keep those calls there or the disk grows with every model you try.
- **Do not key sessions by PID.** macOS recycles pids; a fresh tab could inherit
  a dead tab's conversation. Sessions carry a uuid, and pid/tty are only
  informational.
- **The picker paints on stderr and reads the keyboard from stdin,** exactly
  like the picker reads stdin. Drawing on stdout would be captured by
  `pick=$(...)`; reading keys from a separately opened `/dev/tty` does not put
  the terminal in raw mode, so arrows arrive only after Enter and the menu looks
  frozen (`read -u` looks fine on a pty, which is how it slipped through once).
- **Markers in menus must be one column wide.** `★` and friends are East Asian
  wide and shift every row under them; the default marker is ASCII `* ` with
  `  ` for everything else.
- **`_marv_mlx_` → `_err_` renaming produced `lib/err__moe`** (double underscore)
  because the pattern ate the boundary. Grep for `err__` if you rename again.

## Testing

```sh
make lint    # zsh -n on the three .zsh files, py_compile on err.py
make test    # dispatch  hooks/dispatch, both engines stubbed
             # err.py    explain/ask/sessions against a mock SSE server
             # menus     the real picker code, off a terminal and under a pty
             # smoke     real launcher + err.py + engine dispatch, end to end
```

`tests/smoke.zsh` is the one that matters: it runs the launcher in an
interactive zsh against a mock OpenAI server, in a throwaway `ERR_STATE_DIR` /
`ERR_CONF` / `ERR_HUB_DIR`, and asserts **what the user sees** — the answer
arrives, `err default X` changes what the next question uses, a suggestion lands
in history, an unreachable backend fails loudly. Every bug shipped so far would
have failed one of its checks; none of the older tests would have.

`err doctor` is the manual equivalent for a real install: one pass/warn/fail
line for conf, python, launcher freshness, state, default model, the backend's
server, tools, disk and scratch files. When a report starts with "it doesn't
work", run that first.

Covered without a TTY, without `fm`, without models or network:
dispatch routing for every verb, the preexec guard, unquoted `?`, explain and
ask message construction, session round-trip, redaction, token accounting,
`resume` listing, `new` writing `_ERR_SESSION_ID_FILE`.

**Not covered automatically:** anything that needs a real terminal (the
interactive menus) or real weights (`err run`). Every
menu prints its rows and aborts when it is off a terminal, so the rows are
visible from a pipe. Under a pty, `ERR_PICK_DUMP=1` makes the picker do the
same instead of waiting for keys (that is the seam `tests/menu.zsh` uses):

```sh
zsh ./err-models.zsh run                        # rows on stderr
ERR_PICK_DUMP=1 script -q /dev/null zsh ./err-models.zsh run
```

`_err_input` has the same idea: `ERR_TEST_INPUT=value` answers a prompt without
a terminal.

Manual smoke that does need the real model:

```sh
zsh -f -i    # then: source ./err-launcher.zsh
             # err wtf                   -> explains the last command
             # err and why does it matter?  -> turn 2, history included
             # err resume                -> session picker
```

`err info` and `err run apple-fm` start `fm serve`; `err stop apple-fm` or
`pkill -f 'fm serve'` cleans up. Every server err starts has an idle watchdog
(`err.conf` → `idle_timeout_minutes`): fm via `fm_heartbeat`, each MLX server via
`mlx_heartbeat-<port>`, plus live connections to the port and the server's own
CPU time. `tests/test_err.py` covers both halves (reaped / spared) with a
sub-second timeout and `ERR_WATCHDOG_POLL`.

## Release checklist

1. Bump `VERSION` (and `CHANGELOG.md`).
2. `make lint test`.
3. Help text lives in **one** place: `_err_help_rows()` in `err-models.zsh`
   (the menu rows come from the same list). The README block mirrors it —
   diff them by hand, the smoke test no longer pins it.
4. `install.sh` must stay idempotent (re-runnable), must never duplicate the
   `~/.zshrc` line, and must not require Rust, Xcode CLT or Homebrew.

## Deliberately out of scope

- The **marv** harness (agent loop, tools, TUI) — a different tool, left where
  it was.
- The **marv-mlx pi extension** (`extensions/marv-mlx.ts`, `/marv-mlx-setup`,
  `/marv-mlx-sync`) — not ported. `err info` still exposes what
  such an integration would need.
- The marv-mlx **chat-history TUI** — replaced by the session verbs
  (`new` / `clear` / `resume` / `delete`).
- Bash support in the launcher. `preexec`/`print -z`/`noglob` are zsh features;
  the bash branch in `err-launcher.zsh` is best-effort only.
