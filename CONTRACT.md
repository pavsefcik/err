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
| `err-launcher.zsh` | sourced by `.zshrc` | `err`, `errc`, hooks |
| `err.py` | explain / ask / sessions | `python3 err.py [args]` |
| `err-models.zsh` | ported marv-mlx engine, run as a subprocess | `zsh err-models.zsh <verb> [args]` |
| `lib/err-helpers.zsh` | engine helpers (sourced by `err-models.zsh` only) | `_err_*` |
| `err.conf` | explain/ask config (prompts, backend) | key = value |
| `$ERR_STATE_DIR/config.zsh` | model-launch config (written by `err settings`) | sourced by engine |
| `VERSION` | `0.601.0` | |

`ERR_STATE_DIR` defaults to `$HOME/.cache/marv/mlx` (inherited from marv-mlx on
purpose: existing config, chats and logs keep working). Sessions live in
`$ERR_STATE_DIR/sessions/`.

## Dispatch

`err` is a zsh function; the first word decides the path. **Reserved verbs win
over free text** — `err run` is the model verb, never the question "run".

| Invocation | Goes to |
|---|---|
| `err` | `err.py` (explain last command) |
| `err <anything else>` | `err.py --ask "<text>"` |
| `err new` · `clear` `-c` · `resume [n]` · `delete` | `err.py` (session verbs) |
| `err chat` `switch` `default` `run` `stop` `tui` `list` `curated` `download` `remove` `settings` `info` `cache` `clean` `uninstall` `endpoint` `status` | `err-models.zsh` (same verb, same args) |
| `err version` `-v` `--version` | launcher prints `VERSION` |
| `err help` `-h` `--help` | launcher prints the menu |

`errc <cmd…>` runs `<cmd>`, captures stderr to `_ERR_STDERR_FILE`, then explains
it. `errc` is **not** `noglob`-aliased (it runs real commands).

## Env passed to err.py

| Var | Meaning |
|---|---|
| `_ERR_LAST_CMD` | the command to explain |
| `_ERR_LAST_EXIT` | its exit code (`-1` = unknown) |
| `_ERR_STDERR_FILE` | file holding captured stderr (may not exist) |
| `_ERR_SESSION_ID` | uuid, one per shell, minted by the launcher |
| `_ERR_SUGGEST_FILE` | err.py writes the recommended command here (or nothing) |
| `_ERR_TOKENS_FILE` | err.py writes cumulative session token count here |
| `_ERR_SESSION_ID_FILE` | err.py writes the *new* id here after `new` / `resume N` (a child cannot mutate the shell), one line; the launcher reads it back |

Test/CI overrides (never needed interactively): `ERR_BACKEND`, `ERR_BASE_URL`,
`ERR_SUGGEST` override the matching `err.conf` values so `tests/test_err.py` can
point at a mock server with no `fm` and no network.

The launcher reads `_ERR_SUGGEST_FILE` after the call: if it holds one
non-empty line under 400 bytes, it does `print -z` on it. `_ERR_TOKENS_FILE`
feeds `RPROMPT`.

## The on-device model is a selectable row

`apple-fm` is a sentinel id, not an HF repo: it is served by `fm serve` on
`err.conf` → `port` (default 8080) instead of `:11500`, and needs no download.
It is offered by `_err_pick_installed`, `_err_pick_catalog` and
`_err_pick_default_first`, and handled explicitly by `run`, `switch`, `default`,
`chat`, `stop` and `status`. `err list` stays HF-only (machine-readable) and
`err endpoint` keeps reporting `:11500` for OpenAI clients.

With no `default-model` file, `_err_default_model` derives the default from
`err.conf`: `backend = fm|pcc` means the Apple model is the default (marked `*`),
which matches what a bare `err` already uses. Only an explicit
`err default <model>` overrides that.

## err.conf keys

Existing keys stay. Added:

```
backend        = fm | mlx | pcc     (default fm; mlx = the :11500 server)
mlx_base_url   = http://127.0.0.1:11500
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

* `title` — first question, truncated to 60 chars, used by `err resume`.
* `turns` — written **only** after a redaction pass (`[A-Z_]*(KEY|TOKEN|SECRET|PASSWORD)[A-Z_]*=`,
  `ghp_…`, `sk-…`, `Bearer …` → `«redacted»`).
* Pruned: > 7 days old or > 50 sessions, oldest first.

Exit codes: `0` ok, `1` runtime failure, `2` usage error. Data on stdout,
diagnostics on stderr — the engine and err.py must stay pipe-friendly.
