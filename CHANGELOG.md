# Changelog

All notable changes to err are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/).

## [0.603.0] - 2026-11-23

### Changed

- **`apple-fm` is gated on macOS 27+.** The on-device model does not exist on
  older systems, so it is no longer shown as a row, never becomes the default,
  and `err run apple-fm` refuses with a version message. On macOS 26 and older,
  `err run` offers the installed MLX models; with none installed it opens the
  download catalog instead of saying "no models installed".
- **The question prompt asks for a real suggestion again.** The model decides
  whether a command would help, and if it would, ends its answer with exactly
  one fenced block containing only that command. err takes the *last* fenced
  block, so an earlier example cannot shadow the suggestion. The prompt shows
  the single-quote form (`echo 'Hello, world!'`) that survives zsh history
  expansion.
- **`err new` clears the terminal** before printing `arr // new session`, so a
  fresh session starts at the top of a clean screen. Piped output is untouched.
- **`err resume` rebuilds the conversation on screen.** After the pick it
  prints the resumed session's title and the turns that fit the configured
  history window, in the same `arr //` voice as a live answer. Piped output
  stays silent, and `err resume <n>` keeps working as before.
- **`err resume` titles are one line.** Line breaks from a multi-line question
  or an older session file become a single space, so a title can no longer
  split a resume row in half.
- **Oldest supported macOS is 26 (Tahoe).** The current MLX wheels are built
  for macOS 26 on Apple Silicon; the installer already refuses older systems,
  non-Apple-Silicon hardware, and non-Darwin hosts.

## [0.602.0] - 2026-11-22

### Changed

- **Config simplified.** `err.conf` is the only config file: `thinking` is its
  first line, `config.zsh` and `default-model` are gone (`last-model` is the
  default), the `chat_flag` / `chat_system_prompt` keys and their engine arrays
  are removed (the `err chat` verb they served is gone). `temperature` and
  `max_tokens` are read by err.py, and `max_tokens` also reaches the server.
  Old confs still load; missing keys are appended.
- **The explain and question prompts are in `err.conf` only**, editable with
  `err config`. `err.py` has no built-in copy: a missing or empty prompt key
  makes err refuse to answer and point at `err reset`.
- **`err reset [-y]`** restores the shipped `err.conf`; the old file is kept as
  `err.conf.bak`.
- **Piped input is gone.** `cmd | err wtf` is no longer recorded or read; output
  reaches the model only through `capture = pty`. The `_ERR_STDIN_PIPED` flag is
  removed.
- **Legacy keys are no longer read or upgraded:** `system_prompt` and the
  older-config key appends.
- **Prompts are leaner and more useful.** Explain answers use a few sentences;
  questions are open to technical and non-technical topics; exit-status suffixes
  ask for slightly fuller answers.
- **Suggested commands are made zsh-safe.** Literal double-quoted `!` text is
  converted to single quotes where safe; other unquoted/double-quoted `!`
  characters are escaped before the suggestion reaches shell history.

- **The main menu shows its typed-only commands.** `err 'question'` and
  `err wtf` now appear above the pickable rows under an `Available commands:`
  heading; the `arr //` cursor starts at `err new` and cannot move above it.
  The version line and blank lines are part of the printed (non-TTY) rows too.
- **`err download` skips models already on disk.** The catalog picker omits
  them, and an explicit `err download <installed>` prints
  `arr // <model> already downloaded` instead of re-fetching.

- **Menus and commands trimmed.** `err chat`, `err menu` and `err tui` are gone
  (the old full-screen TUI code and `lib/err_repl.py` removed). `err 'question'`
  and `err wtf` stay typed commands: they are shown in the menu header, not as
  pickable rows.
- **`err config` no longer hits micro's stale-backup prompt** (it opens micro
  with a fresh backup dir and backups off).
- **`err info` is three lines:** `Model`, `Base URL`, `API key: none` (the model
  id is highlighted), or `arr // nothing is running`. `err run` says
  `arr // <model> already running`.
- **`err cleanup`** replaces `clear-cache`, with an `all` row that clears
  kv-cache, logs and sessions together. An explicit target
  (`err cleanup all`, `err cleanup logs`) skips the picker.
- **`err help` opens the menu again.** It sits in the menu's typed-only header
  with `err 'question'` and `err wtf` (not pickable — it would re-open the same
  menu). `err chat`, `err menu` and `err tui` are still ordinary words and
  reach the model like any other question.
- **`err run` with no model is a status answer when one is serving:** it prints
  `arr // <model> already running` instead of opening the picker; switching is
  `err swap`. `err run <model>` still starts/replaces explicitly.
- **`err swap` / `err run` use one rewritten status line:**
  `stopping <old> on http://…` becomes `loading <new> on http://…` (with a
  spinner), which becomes `arr // running: <new> on http://…`. No extra lines
  and no trailing backend chatter. A swap picker omits the model that is
  already serving, and says so when there is nothing else installed.
- **`err new` says what it did:** `arr // new session` (previously silent, so
  it looked like a no-op). The reset itself was working; a test now pins both
  the confirmation and that the next ask carries no history.
- **The turn/token counter follows the current session.** err.py now publishes
  the session's real turn and token totals (`_ERR_TURNS_FILE`, alongside
  `_ERR_TOKENS_FILE`); `new`/`clear` publish `0`, `resume` adopts the resumed
  session's numbers, and the launcher no longer hardcodes `1` or keeps the old
  session's token count. A re-source no longer freezes the prompt either: the
  counters and ownership survive it, and err reclaims its own `RPROMPT` shape
  instead of mistaking it for the user's.
- **`err swap` with nothing running** now answers in err's voice:
  `arr // nothing is running — start one with 'err run <model>'`, and
  `err info` uses the exact same line instead of a shorter variant.
- **`err list` on a terminal is a look-only list:** one `arr //` cursor that
  moves up and down, but selecting does nothing. Piped output stays bare ids
  for scripts, and `--json` is unchanged.
- **`err stop` also ends the conversation:** it mints a fresh session and
  publishes `0` turns / `0` tokens, so the counter clears and the next start
  answers without the previous context.
- **`err cleanup` no longer offers `chats`.** Chat history was removed with the
  old TUI; the directory was legacy. `err cleanup` and `err cache` now cover
  kv-cache, logs and sessions only.
- **Prefix cache expires on its own.** `_err_apc_sweep` deletes APC checkpoint
  files untouched for `apc_max_age_days` (default 7) on every launch and stop,
  and the template now carries the total cap (`apc_total_gb = 6`) alongside a
  saner per-model cap (`apc_disk_max_gb = 2`, was 18).
- **`err swap` no longer repeats the running model** before opening its picker.
- **Faster, colourful launch spinner** (zsh engine and err.py): the
  `loading <model> on http://…` status line is rewritten in place and replaced
  by `arr // running: <model> on http://…` when the server answers. Piped/CI
  runs get the states as separate lines.

### Added

- **Opt-in PTY terminal capture: `capture = pty`.** A PTY relay surrounds the
  interactive shell, preserving TTY behavior while recording bounded command
  output for the next question or explanation. Private OSC markers delimit
  commands; alternate-screen TUIs are excluded. The shipped config enables
  capture; set `capture = off` to disable it. Legacy `capture = on` is ignored
  because the old pipe/tee mode broke TTY apps.
- **`err record` shows what err has recorded.** It prints the latest command,
  exit code and captured output locally, without contacting the model or
  consuming the one-turn context.

### Fixed

- **A transient health probe could undo a successful MLX autostart.** Once the
  engine's `ensure` succeeds, err now uses the existing bounded readiness wait
  instead of failing on a second instantaneous probe.
- **`err run` picked the Apple model and downloaded it from Hugging Face.**
  `_err_headless_run` tested for `apple-fm` only on an explicit argument, then
  fell through to the repo-download path for a picked one. The check now runs
  after the picker (as `err chat` already did), for every entry point.
- **`err download` could try to fetch a menu sentinel.** Picking "Hugging Face
  ID" in the catalog picker yields `__hf_id__`; the help menu re-dispatches its
  pick as `err download __hf_id__`, which used to go straight to the download
  loop (404 on the Hub). `_err_headless_download` now resolves the sentinel —
  prompting for the id — for every entry point, and the tests pin it.
- **The submenu picker sized itself from `$LINES`.** A stale value after a
  window resize made the frame taller than the screen, so the list drew off the
  bottom and could not be scrolled. The picker now reads the live size
  (`stty size`) and also pages (`PgUp`/`PgDn`, `Home`/`End`).

### Changed

- **Submenu order:** `err run` lists the model served last first (Enter on the
  first row is the common case), and the Apple on-device model is always the
  last row — it is a backend, not a repo to download.
- **Menus: one blank line before the key hints.** `_err_pick`, the main TUI,
  chat history and the download screen all separate the list from the footer.
- **`err resume` uses the same picker.** Rows are `err resume <n>  <age>  <tty>
  <cwd>  <title>` with the `arr //` cursor, arrows/`j`/`k`/`PgUp`/`PgDn`, Enter
  resumes, esc prints nothing. Off a terminal it still prints the rows.
- **`err info` never starts a model.** With nothing on :11500 it says so and
  lists the installed ids; it is read-only.
- **`err swap` needs a running model.** Nothing running prints
  `nothing is running — start one with 'err run <model>'` instead of offering a
  picker.
- **`err chat` with no argument attaches to what is running**, and says to run
  `err run` first when nothing is. `err chat <model>` still starts that model.
- **`err list` is only a list.** The terminal picker (details → Run/Swap) is
  gone; use `err info` / `err run` / `err swap`.
- **`err config` prefers micro, then nano**, before `$VISUAL`/`$EDITOR`.
- **Prompts cancel with esc.** `_err_input` (Hugging Face ID, tokens, custom
  model ids, names) is a small line editor: esc cancels, backspace and `^U`
  edit, Enter keeps the default, arrow keys don't cancel.
- **`err clear-cache`** dropped its title and the catch-all row, and an absent
  cache now reads `0B` instead of `empty`.

- **No dialog toolkit: gum is gone.** Menus are err's own (`_err_pick`): rows
  as arguments, `arr //` on the cursor row with the rest indented to match, one
  footer line — `←↓↑→ navigate • esc return • enter submit` (plus `space mark`
  for the multi-select `remove`) — and `PgUp`/`PgDn`/`Home`/`End`, `j`/`k`.
  Painting goes to stderr, keys are read from stdin, only the pick goes to
  stdout. The help menu keeps its `err // <version> // local MLX LLM runner`
  header as a normal heading line. The other dialogs became four small
  primitives: `_err_confirm` (y/N on `read -q`), `_err_input` (`read`, Enter
  keeps the default), `_err_style` (ANSI, colour only on a terminal) and
  `_err_spin` (title + command); `gum pager` is `$PAGER` and `gum write` is
  `$EDITOR`. `err resume` numbers its rows instead of opening a picker.
  `install.sh` no longer downloads gum, `err doctor` no longer checks for it.

- **One config file.** `err.conf` lives in `$ERR_STATE_DIR` (seeded from the
  repo template) and is the only one: `err config` opens it, err.py and the
  engine read the same keys, and repeated `server_flag` / `chat_flag` lines
  replace `config.zsh`'s `ERR_CHAT_FLAGS` / `ERR_SERVER_FLAGS` arrays. An
  existing `config.zsh` is lifted across once (managed block + arrays) and left
  in place. `err settings` and its managed-block rewrite are gone.
- **One temperature, one max_tokens.** `err "<question>"` and `err chat` share
  `temperature` / `max_tokens` (0.7 / 2048 in the template) instead of the
  explain path quietly using 0.3 / 200.
- **`err resume` is a picker.** Rows are `err resume <n>  <age>  <tty>  <cwd>
  <title>`; off a terminal (or with esc) it still prints the list.
- **Dead code removed:** `err runs` (extra servers), `err status`, `err
  endpoint`, `err default`/`set-default`, `err settings` and its managed-block
  writer, `err curated`, the `config.zsh` template writer.

- **`err` and `err help` are one interactive menu** (`lib` support in
  `err-models.zsh`: `_err_help_menu` / `_err_help_rows`). Every row is a real
  command — `err run <model>`, `err info`, `err clear-cache kv-cache 500 MB` —
  and choosing one hands `<verb>\t<rest>` back to the launcher, which
  re-dispatches it through `err`. No `eval`, so the menu can never drift from
  the typed command. Rows that need an argument open a picker (installed
  models, the curated catalog) or a text field (a question); `apple-fm` is
  excluded from `err remove`. Off a terminal the same rows print as text.
- **The vocabulary shrank to what the menu shows.** Removed several legacy
  command wrappers and aliases; `what`/`why` (`err wtf` survives), `status`/`endpoint` (folded into
  `err info`), `cache`/`clean` (`err clear-cache`), `settings` (`err config`),
  `default` (the last model you ran *is* the default), `switch` (`swap`),
  `clear` (`new`), `delete` (`err clear-cache sessions`), `runs` (one model at
  a time), `curated`/`curator`. Hidden but working: `tui`, `version`, `ls`, `rm`.
- **`err info` answers "what is running".** Model, path, base URL and backend;
  nothing running means it offers the installed models, starts the pick, then
  prints the block. `err list` shows the same block for a model that is not
  running (with its size and a Run/Swap choice), and stays plain data when
  piped or given `--json`.
- **`err clear-cache` measures before it deletes:** kv-cache, logs, sessions,
  chats, each with its size, `all` for everything. Weights are never touched.
- **`err stop` and friends speak in `arr //`** — the amber prefix the answers
  carry — so an action line never reads as shell output. Colour is dropped when
  stdout is not a terminal.

### Changed

- **The curated catalog is `err-curator.md`.** The list was `curated-llms.md`,
  a name that read like it belonged to the tools err was forked from, so the
  file, the state cache (`~/.cache/err/err-curator.md`) and the upstream refresh
  URL all carry the new name. Nothing is lost on upgrade: a pre-rename cache is
  adopted (with its `.seed`/`.fetched` sidecars, so a fresher fetched list still
  wins when the bundled bundle is unchanged), and the one-time migration out of
  `~/.cache/marv` lands the catalog under the new name. The menu and `err
  curated` tests no longer hardcode a repo id — they read the first entry out of
  the bundled file, so the curator can rewrite the list without breaking CI.
- **The answer prefix is `arr // `, in amber (`1;38;5;214`).** ` // ` is err's
  own separator (the help screen and the version line already use it), so the
  model's voice reads as one gesture with the rest of the tool instead of a
  stray `arr:`. Amber is the one accent nothing else claims — menu chrome is
  `1;35` magenta, the prompts are `1;36` cyan, `212` pink is the catalog
  headers and the TUI sign-off — so the answer gets its own lane, and warm
  reads as "this is the reply". Escapes are printed only when stdout is a
  terminal and `NO_COLOR` is unset, so `err "<q>" | pbcopy` and the tests still
  get plain `arr // ` text. One helper (`answer_prefix()`) owns it, so the
  streaming open and the `strip_thinking` reprint cannot drift.

### Added

- **Command output can ground explanations.** `cmd | err wtf` reads the
  producer's output from err's stdin. With `capture = pty`, the relay records
  the previous command's bounded output while preserving TTY semantics. Both
  paths feed the same size-limited prompt context.
- **Question mode carries the last command as context** (`Command:`, exit code,
  and the captured output when err has it), for exactly one turn — the
  launcher clears `_ERR_LAST_FRESH` once err has answered. A follow-up like
  `err what is going on?` no longer answers from nothing.

The old pipe-based shell hook was removed because it broke TTY-dependent
programs. The PTY relay is now the opt-in automatic path; piping output remains
available when capture is off.

### Added

- **Every model err starts is shut down again when it goes idle.** The idle
  watchdog used to cover `fm serve` only, so a model started by `err run`,
  `err switch`, `err chat`, `err runs` or err's own mlx autostart held its
  weights in RAM until you noticed. Now every start path arms one watchdog
  (err.conf → `idle_timeout_minutes`, default 10). Idle means: no heartbeat
  stamp, no established connection on the port, and under 0.25 s of CPU since
  the last 20 s poll — so clients err knows nothing about (curl, pi, another
  app) keep the server alive while they work, and `err chat` stamps its own
  port while it streams. Heartbeats are per port (`mlx_heartbeat-<port>`), so a
  chat on `:11501` cannot keep `:11500` awake. `err status` never stamps one:
  it is polled by clients and would otherwise hold every model open forever.
- The engine's `err run apple-fm` never actually armed the watchdog — it passed
  an unset `pid`. Fixed, and the pid is now the listener that owns the port
  rather than the uv shim in `$!`, whose death leaves the child server running.

### Changed

- **The two system prompts now have one definition each.** They were byte-identical
  copies in `err.conf` and in `err.py`'s `DEFAULT_*` constants — four strings,
  two meanings, and nothing to catch the drift when one was edited. The defaults
  live in `err.py`; `err.conf` documents the override instead of restating it.
  `err doctor` now prints each prompt in force with its origin (`builtin` /
  `custom`), via `err.py --prompt explain|question`, so "answers got worse"
  becomes a diagnosis. The explain key is now `explain_system_prompt`
  (`system_prompt` is still read, legacy confs keep working, the new name wins).
  `tests/test_err.py` asserts the prompt actually sent is the one in force, that
  both override keys are honoured, and that `err.conf` stops duplicating text.
- The explain prompt now ends with "Do not include a code block." Its first
  fenced line is fed to the suggestion channel, so a volunteered block meant
  `err what` could put a command in your history.
- **Startup is a spinner, not a log.** `err <question>` shows one animated
  `⠋ starting <model> on http://127.0.0.1:11500` line while the weights load and
  replaces it with `ready <model> on http://127.0.0.1:11500`, in the engine's
  headless launch (so `err run` shares it) and on err.py's fm/autostart waits.
  A pipe or CI gets the same message as one plain line. No duplicated
  "starting" from both err.py and the engine, and no `err:` prefix on
  informational lines — `err:` is reserved for diagnostics.
- **The answer carries an `arr:` prefix** (`arr: Hello! …`), including after a
  503 loading retry, so model output is visibly distinct from err's own lines
  now that the `🤖` emoji is gone.
- **The startup preload is waited out instead of failing the question.**
  mlx-vlm serves `/v1/models` while its preload is still running and rejects
  the first chat request with `503 model_loading`; err treated that as a failed
  answer. Readiness now comes from `/health`'s `model_ready` (falling back to
  `/v1/models` for servers without `/health`), and the chat request retries the
  503 with a `Waiting for <model> to finish loading…` line. A 503 body is also
  printed as its message instead of a raw JSON dict.
- **No emojis in the UX.** The Apple FM ready marker (`🟢`) is gone, as are
  `❌`, `✅`, `❔`, `💥`, `🤔` and the answer's `🤖` prefix: errors read
  `err: …`, explain headers read `<cmd> (exit N)`, and the answer opens with
  `arr:`. Menu glyphs (`✓`, `✗`, `●`, `▲`, arrows) stay — they are layout, not
  decoration.

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
  question. The explain dispatch remains unchanged.
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
- **The explain / ask layer.** `err`, `err <question>` and the session verbs
  (`new`, `clear`, `resume`, `delete`) keep working on Apple
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
