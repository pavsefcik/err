# err

*To err is human.*

Corrects and explains your last shell command, and runs local MLX models on Apple Silicon — on-device by default, no API key, no cloud.

## Requirements

- An Apple Silicon Mac (M-series) on macOS 26 (Tahoe) or later. macOS 26 is
  the oldest supported release: the current MLX wheels are built for it. The
  installer refuses older macOS, non-Apple-Silicon Macs and non-Darwin hosts.
- For the explain / ask half: Apple Foundation Models, i.e. the `fm` CLI that ships with macOS 27 or later. Without `fm`, err still downloads, runs and serves models — only `err` / `err <question>` are unavailable.
- Network for the first install and for model downloads; models run offline once cached.
- No Xcode Command Line Tools, no Homebrew, no compiler required.

## Install

One line. No Xcode Command Line Tools, no Homebrew, no compiler — it installs
`uv` (Astral's standalone installer) and `mlx-vlm` (uv tool) only if they are
missing, and wires the launcher into `~/.zshrc`:

```sh
curl -fsSL https://raw.githubusercontent.com/pavsefcik/err/main/install.sh | sh
```

There is no checkout to keep around: the installer unpacks the latest release
into `~/.err` (`ERR_DIR` to override) and runs itself from there, so the
launcher, engine and config stay together in one directory. Re-running the same
line repairs and updates that directory; `err update` is that re-run, from
inside the shell.

From a checkout, `sh install.sh` installs in place instead:

```sh
sh install.sh                 # or: sh install.sh --dry-run
```

The installer is idempotent and safe to re-run. It:

1. preflights Apple Silicon and macOS 26+;
2. warns — but does not abort — when `fm` is missing;
3. installs `uv` (Astral's standalone installer) only if missing — there is no other binary to download;
4. runs `uv tool install mlx-vlm --with jinja2` only if `mlx_vlm.server` is missing;
5. adds uv's bin directory to `PATH`, prepends the opt-in PTY startup hook, and sources `err-launcher.zsh` in `~/.zshrc` — wiring is idempotent.

`--dry-run` prints the plan without installing anything (a curl dry run unpacks
into a temp dir instead of `~/.err`), `--no-zsh` leaves `~/.zshrc` alone, and
`ERR_DIR` / `ERR_REF` choose the curl-install directory and git ref.

Open a new terminal afterwards (or `source ~/.zshrc`). The older `install.command` only wires the launcher; `install.sh` is the full install.

## Commands

```
err                            the menu (bare)
err -h                         the menu as well
err help                       the menu, typed

err // 0.603.0 // local MLX LLM runner

Available commands:
       err 'question'         ask a question
       err wtf                ask to explain or correct your last command
       err help               show this menu

       err new                start a fresh session
       err resume             resume a session
       err run <model>        start a model on port 11500
       err swap <model>       swap to another model
       err info               what is running, with details
       err stop               stop the running model
       err list               list installed models
       err download <model>   download model(s)
       err remove <model>     remove model(s)
       err config             edit the config file
       err reset              restore the shipped config (old one kept as .bak)
       err cleanup            clear cached state
       err update             update err to the latest release
       err record             show the last command and output
       err uninstall          remove err
       err doctor             check the install
```

`err`, `err -h` and `err help` open the same interactive menu: arrow to a
row, Enter to run it. The rows are the commands themselves, so typing
`err run <model>` from the shell does the same thing. Off a terminal (a script,
a pipe) the menu prints the same list instead of opening a picker. The
question, `wtf` and `help` lines are shown, but they are typed directly — the
cursor starts at `err new` and never moves onto them (`err help` would just
re-open this menu).

`err` with a leading word that is one of the verbs always runs the verb, so a
question that starts with one needs quoting: `err 'why did that fail?'`.


## Explain & ask

After a command, `err wtf` explains what it did — and, if it failed, why.
`err <question>` answers technical or non-technical questions, with follow-ups
kept in context by `err new` and `err resume`. `err record` shows the last
command and captured output without contacting the model.

**Output reaches the model from PTY capture.** Set `capture = pty` in `err config`
and open a new terminal shell. Commands keep a real TTY while err records the
last command's output for the next question or explanation. Alternate-screen
programs (such as vim, less and htop) are excluded. If `ERR_STATE_DIR` or
`ERR_CONF` is set in `~/.zshrc`, place the startup-hook source after that
assignment (or set `ERR_CAPTURE=pty` in the environment). The shipped config
enables PTY capture; set `capture = off` to disable it. Legacy `capture = on`
is ignored.

In interactive zsh, unescaped `!` triggers history expansion outside single
quotes, including inside double quotes. For example, use `echo 'Greetings!'`,
not `echo "Greetings!"`. err also sanitizes suggested commands before they
reach shell history; suggestions are never executed automatically.

The explain layer is configured in the config file (`err config`): `backend = fm`
uses the on-device Apple Foundation Model, `backend = pcc` uses Private Cloud
Compute, and `backend = mlx` points it at the local model server on `:11500`.

**err never executes a command a model suggests.** With the default setting
(`suggest = history`) the suggestion is appended to your shell history: press
**↑** to recall it, read it, edit it, then Enter — or never. `suggest = ask`
drops it into the prompt buffer instead, `suggest = off` stops offering commands.

### When something looks wrong

```sh
err doctor
```

One line per subsystem — config, python, launcher freshness, state, default
model, the backend's server, tools, disk, scratch files — each `ok`, `warn` or
`fail` with the command that fixes it. It also names the two silent traps: a
stale launcher in this shell (`reload`) and a stray `ERR_BACKEND` that overrides
`err.conf`.

### Autostart

With `backend = mlx`, a question you ask when nothing is serving `:11500` starts
the selected model instead of failing — the first one after a reboot can
therefore take a minute while the weights load. Turn it off with
`mlx_autostart = off` in `err.conf` (or `ERR_MLX_AUTOSTART=off`), and err will
print how to start a model instead.

### Quoting

The launcher uses `noglob` so an unquoted `?` does not expand as a filename pattern. Other shell syntax is still parsed before err runs; quote the question when it contains characters such as `' " ( ) ; | & < > !`:

```sh
err "what does 'set -e' do?"
err 'why did (my subshell) exit 1?'
```

Syntax characters such as `|`, `>` and `;` are parsed by zsh before err runs,
so quote them as part of the question.

## Models

err owns the full local-model lifecycle:

- `err list` — installed models. On a terminal it opens a look-only list: one
  `arr //` cursor you can move, selecting does nothing. Piped output stays bare
  ids for scripts.
- `err download` / `err remove` — fetch from the HuggingFace Hub (curated list or
  a typed repo id), or delete from disk. Models already on disk are not offered
  for download. `apple-fm` cannot be removed.
- `err run <model>` / `err swap <model>` — start a model on `:11500`, or replace
  the one running there. `err run` with no model reports
  `arr // <model> already running` when one is serving. One model at a time:
  there is no default to set, the model you last ran is the one err answers from.
- `err info` — the three values an OpenAI client needs: model, base URL
  (`http://localhost:11500/v1`) and API key (`none`), or the same
  `arr // nothing is running — start one with 'err run <model>'` line as
  `err swap`.
- `err stop` — stop what err started. It also ends the conversation: a fresh
  session is prepared for the next start (the turn/token counter goes back to 0).
- `err cleanup` — free space: kv-cache, logs, sessions or all, with
  the size of each shown before you pick (never model weights). `err cleanup all`
  goes straight to the catch-all, and `err cleanup logs` to that target.
  The prefix cache (`apc/`) is bounded in total (`apc_total_gb`) and expires
  entries untouched for `apc_max_age_days` (default 7) on every launch and stop;
  mlx-vlm's own `APC_DISK_MAX_GB` only caps each model directory separately.
- `err run --idle 45m` · `--keep` — how long a model may sit unused. Every
  server err starts is detached (so the next `err` call, pi or an app on
  `:11500` finds it already loaded) and carries an idle watchdog: a request,
  generation (the server's CPU) or a *new* connection keeps it alive, and after
  `idle_timeout_minutes` (default 10) of none it is stopped. A client that
  holds a keep-alive socket open is not "using" it — that socket counts only for
  `idle_socket_grace_seconds` (default 60). Under macOS memory pressure the
  limit drops to `idle_timeout_pressure_minutes` (default 1), because the
  weights are the first thing worth giving back. `--idle <minutes|1h>` overrides
  the timeout for one launch, `--keep` arms no watchdog at all, and every reap
  is logged to `logs/watchdog.log` — `err doctor` shows the watchdog state of a
  running server and re-arms an err-owned one that lost it.
- `err update` — update err itself, then re-run the installer so tools, hook and
  `~/.zshrc` wiring match the new code. A git checkout is fast-forwarded
  (`git pull --ff-only`, never a merge or a clobbered dirty tree); a managed
  curl install refreshes its own `~/.err` snapshot in place. State, config and
  weights are untouched. The shell that ran it still holds the old launcher, so
  err says to open a new terminal (or run `reload`) when the version changed.
### The Apple model is a model choice too

The on-device Apple Foundation Model appears in the same menus as `apple-fm`:

```
err run          # err run apple-fm  (Apple on-device) is one of the choices
err stop apple-fm
```

It is not an MLX repo and needs no download — selecting it starts `fm serve` on
its own port (`err.conf` → `port`, default `8080`) instead of `:11500`, and
`err info` reports it. OpenAI clients and the pi extension expect `:11500`; for
the Apple model the base URL is `http://127.0.0.1:8080/v1`.

State lives in `ERR_STATE_DIR`, default `~/.cache/err` (`err.conf`, `sessions/`, `drafts/`, logs, the prefix cache and the cached catalog). A session is saved for `err resume` from its second answer; before that its turns sit in `drafts/` so the conversation still has its history. `err config` opens the one config file; `temperature` / `max_tokens` there are shared by `err "<question>"`, and extra launch flags are repeated `server_flag = --kv-bits 8` lines. `~/.cache/marv/` belongs to the marv harness and is left alone — on first run err copies its own files across from the old shared location and never touches apc/logs/venvs there.

Model weights are never in err's state: they live in the HuggingFace hub cache, `~/.cache/huggingface/hub/models--<org>--<name>/`, where the model directory holds `snapshots/…` symlinks into `blobs/`. That is why a fully downloaded 4B model can show as a few MB in `du` — the weights are in `blobs/`, shared by link.

## Use from any app

`err run <model>` starts the model behind an OpenAI-compatible endpoint on port `11500`:

```sh
err run mlx-community/Qwen3.5-4B-MLX-4bit
err info       # base URL and model
```

Any OpenAI client works against it — no API key:

```sh
curl -s http://127.0.0.1:11500/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community/Qwen3.5-4B-MLX-4bit","messages":[{"role":"user","content":"hi"}]}'
```

Point your editor, agent or script at `http://127.0.0.1:11500/v1` with the running model's HuggingFace id as the model name.
