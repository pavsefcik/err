# err v0.603.0 — internal contract

Single source of truth for the seams between the three layers. Read before editing
`err-launcher.zsh`, `err.py`, or `err-models.zsh`.

```
.zshrc ──► err-launcher.zsh        interactive shim (hooks, dispatch, facts)
                │
                ├─ free text ─────────────► err.py          explain / ask / sessions
                ├─ session verbs ─────────► err.py          new · clear · resume · delete
                └─ model verbs + help ────► err-models.zsh  ported marv-mlx engine
                                                 │
                                                 └─ mlx_vlm.server on :11500
```

## Files

| File | Role | Public surface |
|---|---|---|
| `err-launcher.zsh` | sourced by `.zshrc` | `err`, hooks, menu entry point |
| `err.py` | explain / ask / sessions | `python3 err.py [args]` |
| `err-models.zsh` | ported marv-mlx engine, run as a subprocess | `zsh err-models.zsh <verb> [args]` |
| `lib/err-helpers.zsh` | engine helpers (sourced by `err-models.zsh` only) | `_err_*` |
| `$ERR_STATE_DIR/err.conf` | the one config (seeded from the repo `err.conf`; `err config` opens it) | key = value |
| `VERSION` | `0.603.0` | |

`ERR_STATE_DIR` defaults to `$HOME/.cache/err`. `~/.cache/marv` is the marv
harness's and is never written by err; a first-run migration copies err's own
files (`sessions/`, catalog) out of the old shared
`~/.cache/marv/mlx` and leaves apc/logs/venvs behind. Sessions live in
`$ERR_STATE_DIR/sessions/`.

## Dispatch

`err` is a zsh function; the first word decides the path. **Reserved verbs win
over free text** — `err run` is the model verb, never the question "run".

| Invocation | Goes to |
|---|---|
| `err` · `-h` `--help` `help` | `err-models.zsh helpmenu` (the interactive menu; rows printed off a TTY) |
| `err wtf` | `err.py` (explain last command) |
| `err <anything else>` | `err.py --ask "<text>"` |
| `err new` · `resume [n]` | `err.py` (session verbs) |
| `err run` `swap` `stop` `list` `info` `download` `remove` `config` `cleanup` `update` `uninstall` `doctor` `version` (`ls`/`rm` aliases) | `err-models.zsh` (same verb, same args) |
| `ensure <model>` | `err-models.zsh`, **hidden** — called by err.py, never by a user |
| `err version` `-v` `--version` | launcher prints `VERSION` |

After a successful `err stop` the launcher also runs `err.py --reset-session`
(hidden): the conversation ends with the server, so the next start begins at
`0t 0` with a fresh session id.

`err wtf` only explains when it stands alone: `err wtf did that fail` is a
question.

**The menu.** The engine owns both the rows (`_err_help_rows`) and the pickers.
A pick returns `<verb>\t<rest>` on stdout; the launcher re-dispatches that
through the `err` function — never `eval` — so a menu row and the typed command
are the same code path. Off a terminal the engine prints the
rows instead, which is what scripts and the tests consume.

**Output reaches the model through the PTY proxy only.** A pipeline ending in
`| err …` is not recorded at all. With `capture = pty`, the first-line `.zshrc` bootstrap in
`lib/err-pty-startup.zsh` replaces the interactive shell with the stdlib proxy
in `lib/err-pty-proxy.py`; the proxy starts a child shell on a PTY, relays bytes
to the user's terminal, and captures bytes between tokenized OSC markers from
`preexec`/`precmd`. Captures are capped at 64 KiB per command and skipped for
alternate-screen TUIs. The question path attaches the last captured output for
exactly one turn. `err record` displays the current command, exit code and
captured output locally without consuming that fresh context. Legacy
`capture = on` is ignored.

## Prompts — one definition, in err.conf

The two system prompts (`explain_system_prompt`, `question_system_prompt`) live
only in `$ERR_STATE_DIR/err.conf`. `err config` edits them; `err reset` restores
the shipped text. `err.py` has no copy: a missing or empty key makes err refuse
to answer. `err doctor` shows the prompt in force by asking
`python3 err.py --prompt explain|question`, which emits `origin<TAB>text` — the
lookup lives in one place (`effective_prompt`), so the engine never re-implements it.

```
explain_system_prompt  = …   in err.conf (err config edits it)
question_system_prompt = …   in err.conf (err config edits it)
```

The split is not cosmetic: the *question* prompt asks for one example command
in a fenced block because `last_fenced_line()` feeds `_ERR_SUGGEST_FILE`, and
that is what makes `suggest = history|ask` useful. The prompt asks the model
to end its answer with that block; a user-supplied prompt must keep the
contract or suggestions stop reaching history. The *explain* prompt must do
the opposite — it says "Do not include a code block" — or `err wtf` could put
a command into your history. Keep a prompt (or a prompt override) on the right
side of that line: the task differs, not the topic.

The prompt is advice, not a guarantee, so the fenced line goes through
`zsh_safe_command()` before it reaches `_ERR_SUGGEST_FILE`: a literal
double-quoted span containing `!` becomes single quoted, anything else gets
`!` escaped (`\!`), and `! cmd` history negation is left alone. No suggestion
may leave an interactive zsh at `dquote>` or evaluate as an event reference.

`err.conf` → `prompt_success` / `prompt_not_found` / `prompt_fail` /
`prompt_unknown` are **not** system prompts: `build_explain_user` appends one of
them to the user message depending on the exit code.

## Env passed to err.py

| Var | Meaning |
|---|---|
| `_ERR_LAST_CMD` | the command to explain |
| `_ERR_LAST_EXIT` | its exit code (`-1` = unknown) |
| `_ERR_STDERR_FILE` | file holding captured stderr (may not exist) |
| `_ERR_STDOUT_FILE` | last command output: PTY proxy capture file or empty when capture is off; cleared before each command |
| `_ERR_LAST_FRESH` | `1` while the last command has not been explained/asked about |
| `_ERR_SESSION_ID` | uuid, one per shell, minted by the launcher |
| `_ERR_SUGGEST_FILE` | err.py writes the recommended command here (or nothing) |
| `_ERR_TOKENS_FILE` | err.py writes the current session's cumulative token count here |
| `_ERR_TURNS_FILE` | err.py writes the current session's turn count here; `new`/`clear` publish `0`, `resume` publishes the resumed session's totals |
| `_ERR_SESSION_ID_FILE` | err.py writes the *new* id here after `new` / `resume N` (a child cannot mutate the shell), one line; the launcher reads it back |

Test/CI overrides: `ERR_CONF` (alternate err.conf, honoured by all three layers),
`ERR_HUB_DIR` (alternate HuggingFace hub), plus the following — never needed
interactively: `ERR_BACKEND`, `ERR_BASE_URL`,
`ERR_SUGGEST` override the matching `err.conf` values so `tests/test_err.py` can
point at a mock server with no `fm` and no network. `ERR_MLX_AUTOSTART`
(`on`/`off`) overrides `err.conf` → `mlx_autostart`.

## Starting the server is err.py's job now

With `backend = mlx`, err.py never says "start it with `err run`" while it can
start it itself. When `mlx_base_url` does not answer `/v1/models` it resolves the
model (`mlx_model_id`) and runs `zsh err-models.zsh ensure <model>`, whose stdout
is sent to **stderr** — stdout belongs to the answer. `ensure` is the swap rule:
nothing there → start; another model there → stop every err server, start this
one on `:11500`; the same model there → wait for it to finish loading (never
kill and relaunch a multi-minute load). `mlx_autostart = off` (or
`ERR_MLX_AUTOSTART=off`) restores the old instruction instead of loading weights.

The launcher reads `_ERR_SUGGEST_FILE` after the call: if it holds one
non-empty line under 400 bytes, it consumes it per `err.conf` → `suggest`:
`history` (default) → `print -s` (↑ recalls; skipped if already the newest
history entry), `ask` → `print -z` (prompt buffer), `off` → discarded. `_ERR_TOKENS_FILE`
feeds `RPROMPT`.

## Idle shutdown — nothing err starts runs forever

Every server err starts is detached, so it also has to be able to die on its
own. Each start path arms one idle watchdog: `err.py:ensure_running` (fm) and
the engine's `_err_headless_launch` via `_err_arm_watchdog` (the MLX server on
`:11500`), both through `python3 err.py --watchdog <pid> [--port N]
[--idle MIN]`. `--watchdog-run` is the detached loop. A server is **idle** when
all of these are true:

1. nobody stamped its heartbeat — `$ERR_STATE_DIR/fm_heartbeat` for fm,
   `$ERR_STATE_DIR/mlx_heartbeat-<port>` for MLX (per port on purpose: a client
   on `:11501` must not keep `:11500` awake). The engine creates the file at
   launch and `err.py` restamps it on every request it makes;
2. it has not appeared as a new connection within `idle_socket_grace_seconds`
   (default 60). A connection is evidence of a request; a socket that has been
   open since yesterday is not, and counting it would let one pooled keep-alive
   client pin a model forever;
3. it burned less than 0.25 s of CPU since the previous 20 s poll — the safety
   net for clients err knows nothing about (curl, pi, an OpenAI SDK), because
   a server generating tokens always burns CPU.

The timeout is `idle_timeout_minutes` (default 10), overridden per launch by
`err run|swap --idle <minutes|Nm|Nh>` and disabled by `--keep` (`--idle 0`).
Under macOS memory pressure (`kern.memorystatus_vm_pressure_level` >= 2) the
limit drops to `idle_timeout_pressure_minutes` (default 1): the weights are the
first thing worth giving back. The watchdog SIGTERMs the **listener** pid, logs
one line to `$ERR_STATE_DIR/logs/watchdog.log` (`stopped <model> :<port> after
10m idle`), deletes the heartbeat and exits as soon as the pid is gone. It also
exits without killing if the pid's start time changed (pid reused).

A server err did not start is never adopted: `_err_adopt_watchdog` (called from
`ensure` and `err doctor`) only arms one for a port with an
`mlx_heartbeat-<port>` file, i.e. a server err started whose watchdog is
missing. `ERR_WATCHDOG_POLL`, `ERR_SOCKET_GRACE`, `ERR_IDLE_PRESSURE_MIN` and
`ERR_MEMORY_PRESSURE` lower/force the knobs for the tests; they are not
user-facing settings. `err info` deliberately does not stamp a heartbeat (it is
polled by clients), so a read-only query can never keep a model alive.

## The on-device model is a selectable row

`apple-fm` is a sentinel id, not an HF repo: it is served by `fm serve` on
`err.conf` → `port` (default 8080) instead of `:11500`, and needs no download.
It is offered by `_err_pick_installed`, `_err_pick_catalog` and
`_err_pick_default_first`, and handled explicitly by `run`, `switch`, `default`,
`stop` and `info`. `err list` stays HF-only (machine-readable) and
`err info --json` keeps reporting `:11500` for OpenAI clients.

The default is `last-model`: the model you last ran or switched to. With no
`last-model`, `_err_default_model` derives it from `err.conf`: `backend = fm|pcc`
means the Apple model. There is no `default-model` file any more.

`err switch <model>` is a move: it starts the model and records it in
`last-model` (plus `backend = mlx`), so the pick survives the shell.

## err.conf keys

Existing keys stay. Added:

```
backend        = fm | mlx | pcc     (managed by `err default`/`err switch`;
                                    mlx = the :11500 server)
mlx_base_url   = http://127.0.0.1:11500
idle_timeout_minutes = 10           (0 = never stop; --idle/--keep override)
idle_timeout_pressure_minutes = 1   (idle limit under macOS memory pressure)
idle_socket_grace_seconds = 60      (how long a new connection counts as use)
mlx_autostart  = on                 (start the saved model when :11500 is down;
                                    off = print "err run <model>" instead)
idle_timeout_minutes = 10           (shut a server err started down when idle)
explain_system_prompt = …           (required; err refuses to answer without it)
question_system_prompt = …          (required; err refuses to answer without it)
history_turns  = 6                  (verbatim turns kept in the window)
suggest        = ask | history | off (what to do with the recommended command)
```

## Session file

A saved session is `$ERR_STATE_DIR/sessions/<uuid>.json`, mode `600`. It is
written only once it has at least **two answers** (`turns`). A conversation
with zero or one answer lives in `$ERR_STATE_DIR/drafts/<uuid>.json` instead
(same shape, mode `600`): the next question still reads it for history, but
`err resume` never lists it. The second answer promotes it to `sessions/` and
removes the draft; `err new` / `err clear` remove both. Files in `sessions/`
with fewer than two turns (from older err versions) are hidden from
`err resume` and deleted by the prune pass.

```json
{"id":"…","created_at":0,"last_used":0,"pid":0,"tty":"…","cwd":"…",
 "title":"…","turns":[{"q":"…","a":"…","cmd":"…","exit":0,"tokens":0}],
 "tokens":0}
```

* `title` — first line of the session, redacted, truncated to 60 chars, shown by
  `err resume`. For an explain turn it is `explain: <command>`; for an ask turn
  it is the question. (`turns[].q` follows the same split: the question for ask
  turns, the whole `Command: … / Exit code: … / <prompt>` block for explain
  turns.) The title is redacted like every other persisted field.
* `turns` — written **only** after a redaction pass (`[A-Z_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Z_]*=`,
  `ghp_…`, `sk-…`, `Bearer …` → `«redacted»`).
* `err resume` lists sessions as `err resume <n>  <age>  '<title>'` (the row is
  the command you would type). `tty` and `cwd` stay in the file but are not
  shown: the quoted title is what tells two sessions apart. On a terminal, Esc
  cancels silently after erasing the menu; off a terminal the rows are printed
  for scripts.
* `err resume` rebuilds the conversation on screen after a successful pick: it
  prints the title and the last `history_turns` turns (the same window the next
  request carries). The human's turns carry `err // ` in cyan and the model's
  answers `arr // ` in amber, so the two voices never blur together. Only a TTY
  gets the replay; piped output stays silent (and uncoloured).
* Pruned: > 7 days old or > 50 sessions, oldest first (drafts follow the
  same bounds, so a dead shell cannot leak one).

Exit codes: `0` ok, `1` runtime failure, `2` usage error. Data on stdout,
diagnostics on stderr — the engine and err.py must stay pipe-friendly.
