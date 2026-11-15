# err

*To err is human.*

Corrects and explains your last shell command, and runs local MLX models on Apple Silicon — on-device by default, no API key, no cloud.

## Requirements

- An Apple Silicon Mac (M-series) on macOS 26 or later.
- For the explain / ask half: Apple Foundation Models, i.e. the `fm` CLI that ships with macOS 27 or later. Without `fm`, err still downloads, runs and serves models — only `err` / `err <question>` are unavailable.
- Network for the first install and for model downloads; models run offline once cached.
- No Xcode Command Line Tools, no Homebrew, no compiler required.

## Install

From an err checkout:

```sh
sh install.sh
```

The installer is idempotent and safe to re-run. It treats the source directory as the install directory (the launcher, engine and config stay together) and:

1. preflights Apple Silicon and macOS 26+;
2. warns — but does not abort — when `fm` is missing;
3. installs `uv` (Astral's standalone installer) and `gum` (sha256-checked GitHub release binary) only if missing;
4. runs `uv tool install mlx-vlm --with jinja2` only if `mlx_vlm.server` is missing;
5. adds the uv/gum bin directories to `PATH` in `~/.zshrc` and sources `err-launcher.zsh` there — each line appended at most once, and printed before it is written.

Open a new terminal afterwards (or `source ~/.zshrc`). The older `install.command` only wires the launcher; `install.sh` is the full install.

## Commands

```
err v0.601.0 // in-terminal LLM & local MLX model runner
TO ERR IS HUMAN.

  err what | why             correct/explain the last command
  err "<question>"           ask a command-related or any other question
  err new                    start a fresh session (old one stays resumable)
  err clear | -c             clear the current session, keep the id
  err resume [n]             list sessions, or resume session number n
  err delete                 delete all sessions
  err status                 show what is running
  err chat <model>           start a model and open the built-in interactive chat
  err switch | swap <model>  switch to another model
  err default <model>        set model as default
  err run <model>            start a model on port 11500
  err runs <model>           start an extra model on :11501+ (keeps :11500)
  err stop <model>           stop a running model (default: all)
  err tui                    interactive TUI (browse / run / download)
  err list                   list installed models err can serve
  err curated                show the full curated model catalog
  err download <model>       download model(s) from the HuggingFace Hub
  err remove <model>         delete model(s) from the disk
  err settings               basic and advanced model settings
  err info <model>           show details for a model (size, family, thinking)
  err cache                  show on-disk footprint (APC, logs, hub, tool env)
  err clean --apc|--logs|--venvs|--all
                             delete regenerable caches (never model weights)
  err uninstall              remove err from your system
  err endpoint               print the base URL / model of the running server
  err doctor                 check the install: config, backends, server, disk
  err version | -v           show the current version
  err help | -h              show this help (this is also what bare `err` does)

The first word decides the path: the verbs above always win, so a question that
starts with one of them needs quoting. `what` / `why` explain the last command
only when they are the whole command — `err why did that fail` is a question.
err never runs a model-suggested command. It appends it to your shell history,
so ↑ recalls it and you decide what to do with it — `suggest = ask` in err.conf
puts it in the prompt buffer instead, `suggest = off` stops offering it.
```

## Explain & ask

After any command, type `err` to get a short explanation of what it did (and a corrected command when it failed). `err <question>` asks a shell or general question; `err new`, `err clear`, `err resume` and `err delete` manage the conversation history that keeps follow-ups in context.

`errc <cmd...>` is the shortcut for the failure case: it runs the command with stderr captured, then calls `err` on it. Use it when you know a command might blow up and you want the explanation immediately:

```sh
errc make build
errc git push origin main
```

The explain layer is configured in `err.conf` (prompts, temperature, backend): `backend = fm` uses the on-device Apple Foundation Model (the default), `backend = pcc` uses Private Cloud Compute, and `backend = mlx` points it at the local model server on `:11500`.

**err never executes a command a model suggests.** With the default setting (`suggest = history` in `err.conf`) the suggestion is appended to your shell history: press **↑** to recall it, read it, edit it, then Enter — or never. `suggest = ask` drops it into the prompt buffer instead, `suggest = off` stops offering commands.

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

`err` is a normal shell function, not a `noglob` alias, so your shell parses the question first. An unquoted `?` now works, but quote the argument when it contains any of `' " ( ) ; | & < > !`:

```sh
err "what does 'set -e' do?"
err 'why did (my subshell) exit 1?'
```

`errc` is never `noglob`-aliased — it runs real commands.

## Models

err owns the full local-model lifecycle:

- `err tui` — interactive menu to browse, run and download models.
- `err list` / `err curated` — what is installed, and the curated catalog for every RAM tier.
- `err download <model>` / `err remove <model>` — fetch from the HuggingFace Hub, or delete from disk.
- `err chat <model>` — start a model and open the built-in interactive chat.
- `err switch <model>` / `err default <model>` — change the active model, or the one used by default. Both also repoint the explain layer (`err.conf` → `backend`), so `err what` / `err <question>` answer with the model you picked: `apple-fm` → the on-device model, any HF repo → the `:11500` server. `err status` shows which backend err is currently using.
- `err run <model>` / `err stop <model>` — start and stop a server (stop defaults to every running model).
- `err status` / `err endpoint` — what is running and where to reach it.
- `err settings` — basic and advanced launch settings.
- `err info <model>` — size, family and thinking capability for a model.
- `err cache` / `err clean` — report the on-disk footprint and delete regenerable caches (never model weights).
  The prefix cache (`apc/`) is bounded at 6 GB in total (`ERR_APC_TOTAL_GB`),
  evicting the least-recently-used model first; mlx-vlm's own `APC_DISK_MAX_GB`
  is per model, so on its own it never bounded the sum.
- `err uninstall` — remove err from the system.

### The Apple model is a model choice too

The on-device Apple Foundation Model appears in the same menus as `apple-fm`,
marked as the default with a leading `*`:

```
err run          # * apple-fm (Apple on-device) is one of the choices
err default      # ... including "make the Apple model the default"
err stop apple-fm
```

It is not an MLX repo and needs no download — selecting it starts `fm serve` on
its own port (`err.conf` → `port`, default `8080`) instead of `:11500`, and
`err status` reports it alongside any MLX server. `err endpoint` keeps pointing
at `:11500` because that is the port OpenAI clients and the pi extension expect;
for the Apple model the base URL is `http://127.0.0.1:8080/v1`.

State lives in `ERR_STATE_DIR`, default `~/.cache/err` (`config.zsh`, `sessions/`, `chats/`, logs, the prefix cache and cached catalogs). `~/.cache/marv/` belongs to the marv harness and is left alone — on first run err copies its own files across from the old shared location and never touches apc/logs/venvs there.

Model weights are never in err's state: they live in the HuggingFace hub cache, `~/.cache/huggingface/hub/models--<org>--<name>/`, where the model directory holds `snapshots/…` symlinks into `blobs/`. That is why a fully downloaded 4B model can show as a few MB in `du` — the weights are in `blobs/`, shared by link.

## Use from any app

`err run <model>` starts the model behind an OpenAI-compatible endpoint on port `11500`:

```sh
err run mlx-community/Qwen3.5-4B-MLX-4bit
err endpoint   # prints the base URL and model
```

Any OpenAI client works against it — no API key:

```sh
curl -s http://127.0.0.1:11500/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community/Qwen3.5-4B-MLX-4bit","messages":[{"role":"user","content":"hi"}]}'
```

Point your editor, agent or script at `http://127.0.0.1:11500/v1` with the running model's HuggingFace id as the model name.
