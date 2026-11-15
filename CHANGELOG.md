# Changelog

All notable changes to err are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- `err "<question>"` / `err what` start the model themselves when `backend = mlx`
  and nothing serves `:11500`. err.py resolves the saved model and calls the
  engine's hidden `ensure` verb, which stops whatever else holds `:11500` first —
  no more `err run <model>` in between, and no more `❌ mlx server not reachable`.
  A model that is already loading is waited for, not killed and relaunched.
  `mlx_autostart = off` in `err.conf` (or `ERR_MLX_AUTOSTART=off`) keeps err from
  loading weights behind your back.

### Fixed

- **Model menus did work — the choice was thrown away.** In zsh, quotes inside
  an associative-array subscript become part of the key, so `_ERR_PICK_MAP["$label"]`
  stored `"…"` and the lookup always missed: rows rendered, the selection mapped
  to nothing, and `err run/switch/default` returned 1 in silence. This is the
  "I can't move from FM" bug.
- Scratch files under `$ERR_STATE_DIR/run` are reaped now (dead shells at
  startup, own files at exit); 246 had accumulated.
- `err default` accepts a remote model (`mlx_model` / `ERR_MLX_MODEL`) without
  requiring local weights.
- New: `err doctor`, `tests/smoke.zsh`, `tests/menu.zsh`, and `ERR_CONF` /
  `ERR_HUB_DIR` so the whole stack can be exercised hermetically.

- `err switch` keeps the pick. It started the model but recorded only
  `last-model`, so the next call could fall back to the model you had just
  switched away from; switch now also writes `default-model` like
  `err default` does.

## [0.601.0]

err and marv-mlx are now one tool.

### Added

- `err doctor` — one pass/warn/fail line per subsystem (config, python, launcher
  freshness, state, default model, the backend's server, tools, disk, scratch
  files), each with the command that fixes it.
- `tests/smoke.zsh` (end to end through the launcher) and `tests/menu.zsh`
  (the real picker driven by a fake `gum`).

### Changed

- Bare `err` prints the help screen instead of explaining the last command.
  Explaining is now explicit: `err what` or `err why` (and a hidden `err wtf`),
  and only when the word stands alone — `err why did that fail` is still a
  question. `errc` is unaffected: it calls the explainer directly.
- The help screen carries the tagline: *TO ERR IS HUMAN.*
- Asking a question with `backend = mlx` and nothing on `:11500` now starts the
  selected model (the engine's new hidden `ensure` verb) instead of failing.
  Opt out with `mlx_autostart = off` / `ERR_MLX_AUTOSTART=off`.
- `err runs [<model>]` starts an **additional** server on the next free port
  from `:11501`–`:11509`, leaving whatever serves `:11500` untouched (for
  comparing two models, or serving one to another app while err keeps its own).
  `err status` lists every server; `err endpoint` and `--json` still report
  `:11500` only, because that is the port clients are pointed at.
- `err swap <model>` is a synonym for `err switch` (same menu, same backend
  repoint).
- A suggested command is no longer dropped straight into the prompt buffer. It
  goes to shell history (`suggest = history`, the new default), so ↑ recalls it
  and nothing is filled in for you. `suggest = ask` restores the buffer
  behaviour, `suggest = off` stops offering commands. Documented in the help
  screen and `err.conf`.

### Fixed

- **Model menus did work — the choice was thrown away.** In zsh, quotes inside
  an associative-array subscript become part of the key, so `_ERR_PICK_MAP["$label"]`
  stored `"…"` and the lookup always missed: rows rendered, the selection mapped
  to nothing, and `err run/switch/default` returned 1 in silence. This is the
  "I can't move from FM" bug.
- Scratch files under `$ERR_STATE_DIR/run` are reaped now (dead shells at
  startup, own files at exit); 246 had accumulated.
- `err default` accepts a remote model (`mlx_model` / `ERR_MLX_MODEL`) without
  requiring local weights.
- New: `err doctor`, `tests/smoke.zsh`, `tests/menu.zsh`, and `ERR_CONF` /
  `ERR_HUB_DIR` so the whole stack can be exercised hermetically.

- **MLX answers work.** With `backend = mlx`, err.py sent err.conf's
  `model_id` (`system`) to the server, so mlx-vlm tried to load a HuggingFace
  repo called `system` and returned `Repository Not Found` — every question
  failed. The model id now comes from the manager (`last-model`, then
  `default-model`), with `ERR_MLX_MODEL` / `mlx_model` as an explicit override.
- `err default` / `err switch` now repoint the explain layer. They used to touch
  only the model manager, so picking an MLX model left `err what` answering from
  Apple FM (`backend = fm` in `err.conf` was never updated). `err status` now
  prints `backend=` and the chosen default so the state is visible.

- `esc` in a model menu aborts instead of falling through to a second
  "Nothing installed" menu with the installed models listed.
- The default row is starred even before `err default` is ever run: with
  `backend = fm` in `err.conf`, `apple-fm` is the default, so the `*` matches
  what a bare `err` actually uses.
- Menu headers are white instead of purple, and start on their own line.
- The on-disk prefix cache is bounded in total (`ERR_APC_TOTAL_GB`, default
  6 GB) instead of per model. Five models used to mean 5 × 5 GB of KV cache
  sitting next to the weights; `err run` now evicts least-recently-used model
  caches first. Per-model cap lowered to 2 GB. `err cache` shows both numbers.

- The `foreign sitecustomize.py …` line no longer prints on every command
  (it was never actionable; `ERR_DEBUG=1` brings it back).
- Menu rows line up: the default marker is ASCII `*`, not a double-width `★`,
  which shifted every row under it.

- **`err info` reports real model size.** It measured the model directory, which
  holds `snapshots/…` symlinks into `blobs/` — so a 2.9 GiB model showed as
  6.5 MB. It now follows snapshots and counts each weight file once.
- **err has its own state root.** `~/.cache/err` instead of borrowing marv-mlx's
  `~/.cache/marv/mlx`; `~/.cache/marv` is left to the marv harness. First run
  copies err's own files across (config, chats, sessions, catalog) and leaves
  apc/logs/venvs behind.

### Merged

- **The model manager.** `err` now carries the full marv-mlx engine: run,
  switch, default, stop, list, curated, download, remove, settings, info,
  cache, clean, endpoint, the TUI, and the built-in chat.
- **Local MLX models behind an OpenAI-compatible endpoint.** `err run <model>`
  serves on `http://127.0.0.1:11500/v1`, so any OpenAI client works with no API
  key.
- **`apple-fm` in the model menus.** The on-device Apple Foundation Model is a
  first-class choice in `err run` / `err switch` / `err default` / `err chat`,
  served by `fm serve` on its own port (`err.conf` → `port`, default `8080`).
  `err status` reports it; `err stop apple-fm` stops it.
- **The explain / ask layer.** `err`, `err <question>`, `errc <cmd...>` and the
  session verbs (`new`, `clear`, `resume`, `delete`) keep working on Apple
  Foundation Models, on-device by default.
- **One install path.** `install.sh` installs `uv`, `gum` and `mlx-vlm` without
  Xcode CLT, Homebrew or Rust, then wires the launcher into `~/.zshrc` once.
- **Shared state.** `ERR_STATE_DIR` keeps the marv-mlx default
  (`~/.cache/marv/mlx`), so existing config, chats, logs and model downloads
  carry over unchanged.

### Deliberately not merged

- **The marv harness.** The coding-agent loop, tools and TUI stay in
  [marv](https://github.com/pavsefcik/marv); err is not that harness.
- **The pi extension.** The marv-mlx pi package and its `/marv-mlx-*` commands
  are not part of err.
- **The chat-history TUI.** err keeps sessions for the explain/ask layer and
  per-model chat logs, but not marv-mlx's browsable chat-history manager.
