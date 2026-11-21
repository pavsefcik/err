# err v0.601.0 — internal contract

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
| `err.conf` | explain/ask config (prompts, backend) | key = value |
| `$ERR_STATE_DIR/config.zsh` | model-launch config (hand-edited; `err config` opens the user config) | sourced by engine |
| `VERSION` | `0.601.0` | |

`ERR_STATE_DIR` defaults to `$HOME/.cache/err`. `~/.cache/marv` is the marv
harness's and is never written by err; a first-run migration copies err's own
files (`config.zsh`, `chats/`, `sessions/`, catalog) out of the old shared
`~/.cache/marv/mlx` and leaves apc/logs/venvs behind. Sessions live in
`$ERR_STATE_DIR/sessions/`.

## Dispatch

`err` is a zsh function; the first word decides the path. **Reserved verbs win
over free text** — `err run` is the model verb, never the question "run".

| Invocation | Goes to |
|---|---|
| `err` · `-h` `--help` | `err-models.zsh helpmenu` (the interactive menu; rows printed off a TTY) |
| `err wtf` | `err.py` (explain last command) |
| `err <anything else>` | `err.py --ask "<text>"` |
| `err new` · `resume [n]` | `err.py` (session verbs) |
| `err run` `swap` `stop` `list` `info` `download` `remove` `config` `cleanup` `uninstall` `doctor` `version` (`ls`/`rm` aliases) | `err-models.zsh` (same verb, same args) |
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

**Output reaches the model exactly one way: `cmd | err wtf`.** The launcher
records the producing side of the pipeline (`_err_is_ours` only sees err when it
is the *first* word), sets `_ERR_STDIN_PIPED=1`, and err.py reads its own stdin.
**A plain command's output is never captured.** The shell would have to make
fd 1 a pipe for the duration (`exec > >(tee …)`), which breaks colours, pagers
and full-screen programs; Atuin's pty-proxy exists because that is the only real
alternative. So `err wtf` after a plain command has the command line and the
exit code only. `errc` was removed for exactly this reason: it *was* that pipe.

Captures are bounded (`output_lines`, default 40; 3000 chars) and cleared at
`preexec` for every command err did not run itself. The question path attaches
the last command plus whatever was piped in as context, for exactly one turn:
the launcher clears `_ERR_LAST_FRESH` once err has answered.

## Prompts — one definition each, err.conf only overrides

The two system prompts are the defaults in `err.py` (`DEFAULT_SYSTEM_PROMPT` for
explain, `DEFAULT_QUESTION_PROMPT` for questions). They are **not** repeated in
`err.conf`: a copy in two files drifts the moment one is edited, and nothing
would notice. `err doctor` prints the prompt in force plus its origin
(`builtin` / `custom`) by asking `python3 err.py --prompt explain|question`,
which emits `origin<TAB>text` — the precedence lives in one place
(`effective_prompt`), so the engine never re-implements it.

```
explain_system_prompt  = …   optional override; wins
system_prompt          = …   legacy name of the above, still read
question_system_prompt = …   optional override
```

The split is not cosmetic: the *question* prompt asks for one example command
in a fenced block because `first_fenced_line()` feeds `_ERR_SUGGEST_FILE`, and
that is what makes `suggest = history|ask` useful. The *explain* prompt must do
the opposite — it says "Do not include a code block" — or `err wtf` could put
a command into your history. Keep a prompt (or a prompt override) on the right
side of that line: the task differs, not the topic.

`err.conf` → `prompt_success` / `prompt_not_found` / `prompt_fail` /
`prompt_unknown` are **not** system prompts: `build_explain_user` appends one of
them to the user message depending on the exit code.

## Env passed to err.py

| Var | Meaning |
|---|---|
| `_ERR_LAST_CMD` | the command to explain |
| `_ERR_LAST_EXIT` | its exit code (`-1` = unknown) |
| `_ERR_STDERR_FILE` | file holding captured stderr (may not exist) |
| `_ERR_STDOUT_FILE` | legacy capture file; nothing writes it now (always empty, truncated at every `preexec`) |
| `_ERR_STDIN_PIPED` | `1` when the recorded line ends in `| err …`: err.py may read its own stdin (bounded) |
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
the engine's `_err_arm_watchdog` (the MLX server on `:11500`
port), both via `python3 err.py --watchdog <pid> [port]`. `--watchdog-run` is
the detached loop; `err.conf` → `idle_timeout_minutes` (default 10) is the
timeout. A server is **idle** only when all three are true:

1. nobody stamped its heartbeat — `$ERR_STATE_DIR/fm_heartbeat` for fm,
   `$ERR_STATE_DIR/mlx_heartbeat-<port>` for MLX (per port on purpose: a client
   on `:11501` must not keep `:11500` awake). `err.py` stamps on every mlx request;
2. no client holds an established connection to the port;
3. it burned less than 0.25 s of CPU since the previous 20 s poll.

(3) is the safety net that makes this work for clients err knows nothing
about — curl, the pi extension, another app — because a server generating
tokens always burns CPU. The watchdog SIGTERMs once the timeout expires and
exits as soon as the pid is gone. `ERR_WATCHDOG_POLL` lowers the poll interval
for tests; it is not a user-facing setting. `err info` deliberately does not
stamp a heartbeat (it is polled by clients), so a read-only query can never
keep a model alive.

## The on-device model is a selectable row

`apple-fm` is a sentinel id, not an HF repo: it is served by `fm serve` on
`err.conf` → `port` (default 8080) instead of `:11500`, and needs no download.
It is offered by `_err_pick_installed`, `_err_pick_catalog` and
`_err_pick_default_first`, and handled explicitly by `run`, `switch`, `default`,
`stop` and `info`. `err list` stays HF-only (machine-readable) and
`err info --json` keeps reporting `:11500` for OpenAI clients.

With no `default-model` file, `_err_default_model` derives the default from
`err.conf`: `backend = fm|pcc` means the Apple model is the default (marked `*`),
which matches what a bare `err` already uses. Only an explicit
`err default <model>` overrides that.

`err switch <model>` is a move, not a one-off: it starts the model **and**
writes `default-model` (plus `backend = mlx`), so the pick survives the shell.
It used to update only `last-model`, which is why the next err call could go
back to the model you had just switched away from.

## err.conf keys

Existing keys stay. Added:

```
backend        = fm | mlx | pcc     (managed by `err default`/`err switch`;
                                    mlx = the :11500 server)
mlx_base_url   = http://127.0.0.1:11500
mlx_autostart  = on                 (start the saved model when :11500 is down;
                                    off = print "err run <model>" instead)
idle_timeout_minutes = 10           (shut a server err started down when idle)
explain_system_prompt = …           (optional; default in err.py — see Prompts)
question_system_prompt = …          (optional; default in err.py)
history_turns  = 6                  (verbatim turns kept in the window)
suggest        = ask | history | off (what to do with the recommended command)
```

## Session file

`$ERR_STATE_DIR/sessions/<uuid>.json`, mode `600`.

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
* Pruned: > 7 days old or > 50 sessions, oldest first.

Exit codes: `0` ok, `1` runtime failure, `2` usage error. Data on stdout,
diagnostics on stderr — the engine and err.py must stay pipe-friendly.
