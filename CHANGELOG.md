# Changelog

All notable changes to err are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/).

## [0.601.0]

err and marv-mlx are now one tool.

### Changed

- Bare `err` prints the help screen instead of explaining the last command.
  Explaining is now explicit: `err what` or `err why` (and a hidden `err wtf`),
  and only when the word stands alone — `err why did that fail` is still a
  question. `errc` is unaffected: it calls the explainer directly.
- The help screen carries the tagline: *TO ERR IS HUMAN.*
- A suggested command is no longer dropped straight into the prompt buffer. It
  goes to shell history (`suggest = history`, the new default), so ↑ recalls it
  and nothing is filled in for you. `suggest = ask` restores the buffer
  behaviour, `suggest = off` stops offering commands. Documented in the help
  screen and `err.conf`.

### Fixed

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
