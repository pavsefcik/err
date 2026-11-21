#!/usr/bin/env zsh

unsetopt xtrace verbose 2>/dev/null

# Pids err launched in this shell session. The EXIT trap kills these so child
# servers don't outlive their manager. Servers from other sessions or external
# processes are discovered live via lsof+ps in _err_running and aren't tracked
# here, so we won't kill what we didn't start.
typeset -ga _ERR_SESSION_PIDS=()

# Self-contained helpers (no dependence on err()'s locals) live in lib/.
local _ERR_SRC_DIR="${0:A:h}"
source "$_ERR_SRC_DIR/lib/err-helpers.zsh"

_err_engine_main() {
  local ERR_DEBUG=false
  local hub_dir="${ERR_HUB_DIR:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
  local state_dir="${ERR_STATE_DIR:-$HOME/.cache/err}"
  local log_dir="$state_dir/logs"
  local config_file="$state_dir/err.conf"
  local chat_dir="$state_dir/chats"

  typeset -ga ERR_CHAT_FLAGS=( --max-tokens 2048 --temperature 0.7 )
  typeset -ga ERR_SERVER_FLAGS=()

  # Version query: handled before the tool check so it works even on a
  # half-broken install — reporting the version shouldn't depend on uvx.
  if [[ $# -eq 1 && "$1" == (-v|--version|-V|version) ]]; then
    print "$(<"$_ERR_SRC_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
    return 0
  fi

  # cache/clean are on-disk reporting + hygiene. Like version, they must work on
  # a half-broken install (no uv/mlx-vlm), and `clean` must not depend on a
  # tool check — so they are handled here, before it. Both keep the CLI contract:
  # data on stdout, errors on stderr, exit 0 ok / 1 failure / 2 usage error.
  if [[ "${1:-}" == (cache|clean) ]]; then
    _err_migrate_legacy_state
    # The report and clean read APC overrides from the one config file. No
    # state dirs are created here: cache only reads, clean removes. (The config
    # is loaded by the main path; here we only need the APC env.)
    case "$1" in
      cache) _err_cache_cmd "$state_dir" "$hub_dir" "$log_dir" "${@:2}" ;;
      clean) _err_clean_cmd "$state_dir" "$hub_dir" "${@:2}" ;;
    esac
    return $?
  fi

  local cmd missing=()
  for cmd in curl uvx mlx_vlm.server; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    # One-shot repair: interactive startup auto-installs a missing mlx-vlm
    # (the one missing piece uv can fix on its own); anything else — or any
    # missing tool in headless mode — still aborts with instructions so
    # automation (pi's model_select hook) fails loudly and fast.
    if (( $# == 0 && ${#missing[@]} == 1 && ${missing[1]} == "mlx_vlm.server" )) \
       && command -v uv >/dev/null 2>&1; then
      print -u2 "err: mlx-vlm not installed — installing (one-time)…"
      if uv tool install mlx-vlm --with jinja2 >/dev/null 2>&1 \
         && command -v mlx_vlm.server >/dev/null 2>&1; then
        print -u2 "err: mlx-vlm installed."
        missing=()
      fi
    fi
    if (( ${#missing[@]} > 0 )); then
      print -u2 "err: missing required tool(s): ${missing[*]}"
      print -u2 ""
      print -u2 "Install with:"
      print -u2 "  install uv (https://astral.sh/uv), then: uv tool install mlx-vlm --with jinja2"
      return 1
    fi
  fi

  # One-time migration from the old `ymlx` layout (idempotent; no-op after the
  # first run). Must run BEFORE creating the new state dir so the target-absent
  # guard holds.
  _err_migrate_legacy_state

  mkdir -p "$state_dir" "$log_dir" "$chat_dir"

  # The curated download list ships bundled in this repo (`err-curator.md`), but
  # upstream can add models between releases, so an interactive startup refreshes
  # a cached copy from GitHub (`_err_catalog_sync`: TTL-gated, ~5s timeout,
  # offline keeps what we have). The cache sits at the legacy path sibling tools
  # read (`~/.cache/err/err-curator.md`) and is what the Download menu and
  # `err download` serve. A `ERR_CATALOG` override points at a different
  # list and disables the refresh; ERR_CATALOG_TTL (seconds, 0 = every run,
  # `never` = off) and ERR_CATALOG_URL tune it.
  local curated_file="${ERR_CATALOG:-}"
  if [[ -z "$curated_file" ]]; then
    # Never fetch on a headless verb: `err run` sits on pi's model_select
    # path and must stay fast. Seeding from the bundled copy still happens, so
    # headless verbs read the same (last fetched) list as `err download`.
    local catalog_url=""
    (( $# == 0 )) && catalog_url="${ERR_CATALOG_URL:-$_ERR_CATALOG_URL_DEFAULT}"
    if _err_catalog_sync "$_ERR_SRC_DIR/err-curator.md" \
         "$state_dir/err-curator.md" "$catalog_url" "${ERR_CATALOG_TTL:-3600}"; then
      curated_file="$state_dir/err-curator.md"
    else
      curated_file="$_ERR_SRC_DIR/err-curator.md"
    fi
  fi


  typeset -g ERR_QUICK_THINKING="default"
  typeset -g ERR_QUICK_TEMP=""
  typeset -g ERR_QUICK_MAX_TOKENS=""
  typeset -g ERR_QUICK_SYSTEM_PROMPT=""
  typeset -g ERR_QUICK_MOE_CACHE=""
  typeset -g _ERR_STTY_SAVED=""
  _ERR_STTY_SAVED="$(stty -g 2>/dev/null)"

  # ── UI primitives ──────────────────────────────────────────────────
  # err carries no dialog toolkit: these are what pickers and prompts need, in
  # plain zsh. Menus are _err_pick (further down); colour is dropped when the
  # output is not a terminal, like err.py's answers.
  _err_style() {  # [--foreground N] [--bold] text…
    local fg="" bold=0 text=""
    while (( $# )); do
      case "$1" in
        --foreground) fg="${2:-}"; shift 2 ;;
        --bold)       bold=1; shift ;;
        *)            text+="${text:+ }$1"; shift ;;
      esac
    done
    if [[ -t 1 && -n "$text" ]]; then
      local seq=""
      [[ -n "$fg" ]] && seq="38;5;${fg}"
      (( bold )) && seq="${seq:+${seq};}1"
      print -r -- $'\e['"${seq:-0}"'m'"$text"$'\e[0m'
    else
      print -r -- "$text"
    fi
  }

  # y/N. 0 only on an explicit yes, and no terminal means no.
  _err_confirm() {  # question
    local q="${1:-Continue?}" reply=""
    q="${q//\\n/$'\n'}"   # callers pass "question\ncontext"
    if [[ ! -t 0 ]]; then
      print -u2 -- "$q [y/N] (no terminal — no)"
      return 1
    fi
    print -n -- "$q [y/N] " >&2
    if read -q reply; then print >&2; return 0; fi
    print >&2
    return 1
  }

  # One-line prompt; Enter keeps the default, esc cancels (returns 1), ^U
  # clears, backspace deletes. The answer goes to stdout, the prompt to stderr.
  _err_input() {  # prompt [default]
    local prompt="${1:-}" def="${2:-}" buf="" ch tail
    # Test seam: answer prompts without a terminal (see tests/).
    if [[ -n "${ERR_TEST_INPUT+set}" ]]; then
      print -r -- "${ERR_TEST_INPUT:-$def}"
      return 0
    fi
    if [[ ! -t 0 ]]; then
      print -r -- "$def"
      return 0
    fi
    print -n -- "$prompt" >&2
    while true; do
      read -s -k 1 ch || { print >&2; return 1 }
      case "$ch" in
        $'\r'|$'\n') break ;;
        $'\e')
          # esc cancels, but an arrow key is ESC [ A — swallow it, keep editing.
          tail=""
          read -s -t 0.05 -k 1 tail
          if [[ "$tail" == ('['|'O') ]]; then
            read -s -t 0.05 -k 1 tail
            continue
          fi
          print >&2
          return 1 ;;
        $'\x7f'|$'\b')
          if [[ -n "$buf" ]]; then
            buf="${buf[1,-2]}"
            print -n -- $'\b \b' >&2
          fi ;;
        $'\x15')  # ^U
          while [[ -n "$buf" ]]; do
            buf="${buf[1,-2]}"
            print -n -- $'\b \b' >&2
          done ;;
        $'\x03')  # ^C
          print >&2
          return 1 ;;
        *) buf+="$ch"; print -n -- "$ch" >&2 ;;
      esac
    done
    print >&2
    [[ -z "$buf" ]] && buf="$def"
    print -r -- "$buf"
  }

  # Run a command under a one-line title.
  _err_apply_quick() {
    # Thinking is per-model-family and applied at launch / per request (see
    # _err_apply_launch_thinking), so it is NOT written
    # into ERR_SERVER_FLAGS here — that would be a second source of truth.
    if [[ -n "$ERR_QUICK_TEMP" ]]; then
      _err_replace_or_append ERR_CHAT_FLAGS --temperature "$ERR_QUICK_TEMP"
      # mlx_vlm.server has no server-level temperature flag — temperature is a
      # per-request field, which err.py sends (and API clients send).
    fi
    if [[ -n "$ERR_QUICK_MAX_TOKENS" ]]; then
      _err_replace_or_append ERR_CHAT_FLAGS --max-tokens "$ERR_QUICK_MAX_TOKENS"
      _err_replace_or_append ERR_SERVER_FLAGS --max-tokens "$ERR_QUICK_MAX_TOKENS"
    fi
    # Streaming MoE expert-cache budget (GiB). Non-MoE models ignore it.
    if [[ -n "$ERR_QUICK_MOE_CACHE" ]]; then
      export ERR_MOE_CACHE_GB="$ERR_QUICK_MOE_CACHE"
    fi
    # System prompts are per-request only: mlx_vlm has no --system-prompt flag
    # (server or chat), and ERR_CHAT_FLAGS is informational, so there is
    # nothing to write here — err.py injects ERR_QUICK_SYSTEM_PROMPT
    # into the request messages and API clients pass it in the body.
  }


  # Self-heal the APC sitecustomize in the mlx-vlm uv tool env: a
  # `uv tool update` reinstalls the env and drops it. With it in place, every
  # server launch — err's or a foreign one (the marv harness's embedded
  # launch, a manual mlx_vlm.server call) — defaults prefix caching on.
  _err_install_apc_sitecustomize "$_ERR_SRC_DIR/lib/err-apc-sitecustomize.py"

#
# HuggingFace token handling. mlx-vlm downloads models from the HF Hub; without
# a token it warns "sending unauthenticated requests". These helpers expose an
# existing token (env or the on-disk cache that `huggingface-cli login` / an
# earlier err login wrote) and offer a one-shot wizard to save one.
#
_err_hf_token_file() {
  print -r -- "${HF_HOME:-$HOME/.cache/huggingface}/token"
}

_err_hf_has_token() {
  [[ -n "$HF_TOKEN" ]] && return 0
  [[ -s "$(_err_hf_token_file)" ]] && return 0
  return 1
}

_err_hf_setup() {
  local action tok tf
  tf=$(_err_hf_token_file)
  echo
  _err_style --foreground 212 --bold "HuggingFace authentication"
  _err_style --foreground 250 "err downloads models from the HuggingFace Hub. Adding a token gets you"
  _err_style --foreground 250 "higher rate limits + faster downloads and unlocks gated/private models."
  _err_style --foreground 244 "(Without one, err just warns and still works for public models.)"
  echo
  local action
  action=$(_err_pick --header 'Hugging Face token?' "Paste a token now" "Skip (public models only)")
  if [[ -z "$action" || "$action" != "Paste"* ]]; then
    echo "Skipped — public model downloads will simply be unauthenticated."
    return 1
  fi
  tok=$(_err_input 'Token (hf_..., https://huggingface.co/settings/tokens): ')
  tok="${tok//[[:space:]]/}"
  if [[ -z "$tok" ]]; then
    echo "No token entered — skipped."
    return 1
  fi
  mkdir -p "${tf:h}"
  chmod 700 "${tf:h}" 2>/dev/null
  printf '%s\n' "$tok" > "$tf"
  chmod 600 "$tf" 2>/dev/null
  export HF_TOKEN="$tok"
  echo "✓ Authenticated — saved to $tf (shared with other HuggingFace tools)."
  return 0
}

# If a token is already on disk (written by an earlier err login or by
# `uvx huggingface_hub[cli] huggingface-cli login`), export it so every download
# subprocess this session is authenticated and the warning stops appearing.
if [[ -z "$HF_TOKEN" && -s "$(_err_hf_token_file)" ]]; then
  export HF_TOKEN="$(<"$(_err_hf_token_file)")"
fi

# Keep weight blobs inside each model's own folder (models--org--name/blobs/)
# instead of huggingface_hub's cache-wide shared store (hub/blobs/<hex>/).
# huggingface_hub >=1.33 runs that Xet-backed shared-blob store by default,
# so non-git files (large .safetensors, tokenizers) get deduplicated at the
# hub root and a model folder only keeps symlinks to it — which reads as a
# weird download if, like err, you want each cache entry to be self-contained.
# Disable it so huggingface_hub stores those blobs as regular files under the model dir.
export HF_HUB_DISABLE_SHARED_BLOBS=1

  # Every server err starts is detached (`&!` / nohup) and would otherwise
  # outlive the command that started it and hold its weights in RAM forever.
  # Arm err.py's idle watchdog for it: inactivity is measured from the port's
  # heartbeat, live connections and the server's own CPU time, so this works
  # for clients err knows nothing about (curl, pi, another app).
  #
  # The watchdog gets the pid that LISTENS on the port, not `$!`: `$!` is the
  # uv/mlx-vlm shim, and SIGTERM to the shim leaves the real server (and its
  # RAM) behind. Do not arm this from a read-only query path — `err info`
  # is polled by clients and would keep every model awake.
  _err_arm_watchdog() {
    local port="$1" launched="$2" pid
    [[ -n "$port" ]] || return 0
    : > "$state_dir/mlx_heartbeat-$port" 2>/dev/null
    pid=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n1)
    [[ -n "$pid" ]] || pid="$launched"
    [[ -n "$pid" ]] || return 0
    python3 "$_ERR_SRC_DIR/err.py" --watchdog "$pid" "$port" >/dev/null 2>&1 &!
    return 0
  }

  # Discover running mlx_vlm.server instances on err's ports (11500-11509) by
  # asking the OS, not a state file. Emits one TSV line per server:
  # pid<TAB>port<TAB>model. The model id is parsed from the process's --model arg.
  _err_running() {
    local p lpid cmd m
    for p in {11500..11509}; do
      lpid=$(lsof -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null | head -n1)
      [[ -z "$lpid" ]] && continue
      cmd=$(ps -o command= -p "$lpid" 2>/dev/null)
      # Renamed servers (lib/sitecustomize.py setproctitle) have a command line
      # that IS the model id; everything else is parsed from --model.
      if [[ "$cmd" == *"--model "* ]]; then
        m="${cmd#*--model }"
        m="${m%% *}"
      else
        [[ -z "$cmd" ]] && continue
        m="${cmd%% *}"
      fi
      [[ -z "$m" ]] && continue
      printf '%s\t%s\t%s\n' "$lpid" "$p" "$m"
    done
  }

  # Remove a pid from the session-tracked list (called after we kill it, so
  # the EXIT trap doesn't redundantly target a dead pid).
  _err_drop() {
    local target="$1" i
    local -a keep=()
    for i in "${_ERR_SESSION_PIDS[@]}"; do
      [[ "$i" == "$target" ]] && continue
      keep+=( "$i" )
    done
    _ERR_SESSION_PIDS=( "${keep[@]}" )
  }

  _err_stop_all() {
    local pid port model
    while IFS=$'\t' read -r pid port model; do
      if [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; then
        echo "Stopped: $model (:$port)"
      fi
    done < <(_err_running)
    _ERR_SESSION_PIDS=()
  }

  # Headless (non-interactive) helpers -------------------------------
  # pi always talks to :11500, so headless mode is primary-port only and never
  # uses the parallel-run fallback that _err_find_port offers the menu.
  _err_running_model() {  # echoes pid\tport\tmodel for :11500 (or nothing)
    local pid port model
    while IFS=$'\t' read -r pid port model; do
      [[ "$port" == "11500" ]] && { printf '%s\t%s\t%s\n' "$pid" "$port" "$model"; return 0; }
    done < <(_err_running)
    return 1
  }

  # Fast, colour-cycling launch wheel. Terminal only: a pipe/CI/test gets the
  # plain message once (from the callers) and no carriage returns.
  _err_spin_tick() {  # index message
    local i="${1:-1}" msg="${2:-}"
    local -a frames=( ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏ )
    local -a colors=( 45 51 87 123 129 165 201 207 214 220 )
    local f="${frames[$(( (i - 1) % ${#frames} + 1 ))]}"
    local c="${colors[$(( (i - 1) % ${#colors} + 1 ))]}"
    printf '\r\e[38;5;%sm%s\e[0m %s' "$c" "$f" "$msg" >&2
  }

  # One status line that is rewritten in place: stopping -> loading -> running.
  # Off a terminal there is nothing to rewrite, so each state gets its own line.
  _err_status_set() {
    if [[ -t 2 ]]; then
      printf '\r\033[K%s' "$*" >&2
    else
      print -u2 -- "$*"
    fi
  }

  # Drop the in-place status line before an error message needs a fresh line.
  _err_status_clear() {
    [[ -t 2 ]] && printf '\r\033[K' >&2
    return 0
  }

  _err_headless_launch() {
    local model="$1" want_port="${2:-11500}"
    local unsupported
    if unsupported=$(_err_model_unsupported_reason "$model" "$hub_dir"); then
      _err_status_clear
      print -u2 "err: $model can't be served — $unsupported."
      print -u2 "MLX-quantized repos run directly (e.g. mlx-community/…-4bit)."
      return 1
    fi
    local port="$want_port"
    if ! _err_port_free "$port"; then
      _err_status_clear
      print -u2 "err: port $port is busy — stop the running model first (err stop)"
      return 1
    fi
    local safe="${model//\//_}"
    local log="$log_dir/${safe}-${port}.log"
    local -a launch_flags=( "${ERR_SERVER_FLAGS[@]}" )
    _err_apply_launch_thinking launch_flags "$model" "$hub_dir"
    # Prefix caching: without this the server re-prefills the whole
    # conversation every turn (mlx-vlm leaves APC off by default).
    _err_export_apc_env "$state_dir"
    # Bound the on-disk prefix cache in TOTAL before a server writes more into
    # it; mlx-vlm's own cap is per model directory, so it never bounds the sum.
    _err_apc_sweep "$state_dir/apc"
    # Rename this server to the model name in Activity Monitor / ps (see
    # lib/sitecustomize.py), so heads-up monitoring shows which model is up.
    _err_build_server_argv "$model" "$port" "$hub_dir" "${launch_flags[@]}"
    ERR_PROCTITLE="$model" PYTHONPATH="$_ERR_SRC_DIR/lib${PYTHONPATH:+:$PYTHONPATH}" \
      "${reply[@]}" >"$log" 2>&1 &!
    local pid=$!
    local url="http://127.0.0.1:$port"
    # One line, rewritten: loading (with spinner), then the
    # `arr // running: …` action line replaces it.
    _err_status_set "loading $model on $url"
    local spin=0
    if [[ -t 2 ]]; then
      spin=1
      _err_spin_tick 1 "loading $model on $url"
    fi
    local i
    for i in {1..6000}; do   # ~ up to 20 min for large/quantized models
      (( spin )) && _err_spin_tick "$i" "loading $model on $url"
      if ! kill -0 "$pid" 2>/dev/null; then
        (( spin )) && printf '\r\033[K' >&2
        print -u2 "err: server exited while loading — last log lines:"
        tail -n 20 "$log" >&2
        return 1
      fi
      if _err_server_ready "$port"; then
        (( spin )) && printf '\r\033[K' >&2
        _err_say "running: $model on $url"
        return 0
      fi
      sleep 0.2
    done
    (( spin )) && printf '\r\033[K' >&2
    print -u2 "err: timed out waiting for $model to serve — log: $log"
    return 1
  }

  # ── headless model pickers ────────────────────────────────────────
  # Every management verb falls back to one of these when it is called with no
  # model id, so `err run` / `err switch` / `err download` are menus, and
  # `err run <id>` still works verbatim for scripts and the pi extension.
  typeset -gA _ERR_PICK_MAP=()

  # The on-device Apple model is a backend, not an MLX repo: it is served by
  # `fm serve` on its own port (err.conf `port`, default 8080) and needs no
  # download. It appears in the same menus as a sentinel id so `err run`,
  # `err swap` understands it.
  typeset -g _ERR_FM_ID="apple-fm"

  _err_fm_port() {
    local f p=""
    f=$(_err_conf_path)
    [[ -r "$f" ]] && p=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$f" 2>/dev/null \
      | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -dc '0-9')
    print -r -- "${p:-8080}"
  }

  # pid of the fm server, but only if the listener really is `fm` (not some
  # unrelated service that happens to own the port).
  _err_fm_running() {
    local port=$(_err_fm_port) pid cmd
    # Shared with err.py's idle watchdog (state_dir/fm_heartbeat): using err
    # through the engine must count as activity, or the watchdog SIGTERMs a
    # perfectly live server mid-conversation.
    : > "$state_dir/fm_heartbeat" 2>/dev/null
    pid=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n1)
    [[ -n "$pid" ]] || return 1
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    # match on the executable's basename: /usr/bin/fm, /usr/local/bin/fm, …
    [[ "${${cmd%% *}:t}" == fm ]] || return 1
    print -r -- "$pid"
  }

  _err_fm_start() {
    local pid port; port=$(_err_fm_port)
    if pid=$(_err_fm_running); then
      _err_say "$_ERR_FM_ID already running"
      _err_note_last_model "$_ERR_FM_ID"
      return 0
    fi
    if ! command -v fm >/dev/null 2>&1; then
      print -u2 "err: the Foundation Models CLI (fm) is missing — it ships with macOS 26+"
      return 1
    fi
    local log="$log_dir/fm-$port.log" fmpid
    local url="http://127.0.0.1:$port"
    _err_status_set "loading $_ERR_FM_ID on $url"
    local spin=0
    if [[ -t 2 ]]; then
      spin=1
      _err_spin_tick 1 "loading $_ERR_FM_ID on $url"
    fi
    nohup fm serve --host 127.0.0.1 --port "$port" >"$log" 2>&1 &!
    fmpid=$!
    local i
    for i in {1..300}; do
      (( spin )) && _err_spin_tick "$i" "loading $_ERR_FM_ID on $url"
      if curl -fs -o /dev/null --max-time 1 "$url/v1/models" 2>/dev/null; then
        if (( spin )); then
          printf '\r\033[K' >&2
        fi
        _err_say "running: $_ERR_FM_ID on $url"
        print "  endpoint: $url/v1"
        # One place arms the idle watchdog (err.py owns the logic); without it
        # an engine-started fm server never shuts down. The pid must be the one
        # we just started: `pid` is still unset on this path.
        python3 "$_ERR_SRC_DIR/err.py" --watchdog "${fmpid:-$pid}" >/dev/null 2>&1 &!
        _err_note_last_model "$_ERR_FM_ID"
        return 0
      fi
      sleep 0.2
    done
    (( spin )) && printf '\r\033[K' >&2
    print -u2 "err: fm did not answer on :$port — log: $log"
    return 1
  }

  _err_fm_stop() {
    local pid port; port=$(_err_fm_port)
    if pid=$(_err_fm_running); then
      kill "$pid" 2>/dev/null && _err_say "stopped the Apple Foundation Model (:$port)"
      return 0
    fi
    return 1
  }

  # The model `err run` prefers. With no explicit choice, err's own
  # backend is the honest default: `backend = fm|pcc` in err.conf means the
  # on-device Apple model is what you get when you just type `err`.
  # err's own action lines — "here is what I just did". They carry the same
  # `arr //` prefix and amber as the model's answers, so a status line never
  # reads as shell output. Colour only on a terminal, like err.py's answers.
  _err_say() {
    if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
      print -r -- $'\e[1;38;5;214marr //\e[0m '"$*"
    else
      print -r -- "arr // $*"
    fi
  }

  _err_default_model() {
    # There is no `err default` any more: the model you last ran or swapped to
    # IS the default, which is also what err.py answers from.
    local f="$state_dir/default-model" m="" b="" last="$state_dir/last-model"
    if [[ -r "$last" ]]; then
      m="$(<"$last")"; m="${m//[[:space:]]/}"
    fi
    if [[ -z "$m" && -r "$f" ]]; then
      m="$(<"$f")"; m="${m//[[:space:]]/}"
    fi
    if [[ -z "$m" && -r "$(_err_conf_path)" ]]; then
      b=$(grep -E '^[[:space:]]*backend[[:space:]]*=' "$(_err_conf_path)" 2>/dev/null \
        | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')
      [[ "$b" == (fm|pcc) ]] && m="$_ERR_FM_ID"
    fi
    [[ -n "$m" ]] && print -r -- "$m"
  }

  _err_last_model() {      # last model that served on :11500
    local f="$state_dir/last-model" m
    [[ -r "$f" ]] || return 1
    m="$(<"$f")"
    m="${m//[[:space:]]/}"
    [[ -n "$m" ]] && print -r -- "$m"
  }

  _err_note_last_model() { [[ -n "${1:-}" ]] && print -r -- "$1" > "$state_dir/last-model" }

  _ERR_FM_LABEL="apple-fm  (Apple on-device)"

  # Rewrite one `key = value` line in err.conf, leaving every other line
  # untouched. This is how `err run`/`err swap` reach the explain layer:
  # err.conf -> backend is what err.py actually reads.
  # Tests and multi-profile setups can point the whole stack at another file.
  # ── one config file ────────────────────────────────────────────────
  # `$ERR_STATE_DIR/err.conf`, seeded from the repo template on first run. Flat
  # `key = value`, so err.py (stdlib) and this engine read the same file. Flags
  # are repeated `server_flag = --kv-bits 8` lines instead of a zsh array —
  # which is why config.zsh is gone: one file, one vocabulary, no managed block.
  _err_conf_path() { print -r -- "${ERR_CONF:-$config_file}" }

  _err_conf_get() {
    local key="$1" f
    f=$(_err_conf_path)
    [[ -r "$f" ]] || return 1
    # ${key} braces matter: `$key[...]` is an array subscript in zsh, not a
    # regex — it fails with "bad output format specification".
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$f" 2>/dev/null | head -1 \
      | sed 's/^[^=]*=[[:space:]]*//' | sed 's/[[:space:]]*$//'
  }

  _err_conf_set() {
    local key="$1" value="$2" f tmp
    f=$(_err_conf_path)
    [[ -r "$f" ]] || return 1
    tmp=$(mktemp)
    awk -v k="$key" -v v="$value" '
      BEGIN { done = 0 }
      $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print k " = " v; done = 1; next }
      { print }
      END { if (!done) print k " = " v }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
  }

  # First run: copy the template, then lift an old config.zsh across once (its
  # managed block and flag arrays become keys here), leaving it in place so a
  # downgrade still finds it.
  _err_conf_seed() {
    local f old="$state_dir/config.zsh" line k v kv
    f=$(_err_conf_path)      # ERR_CONF wins, then the state copy
    [[ -e "$f" ]] && return 0
    mkdir -p "${f:h}" 2>/dev/null
    if [[ -r "$_ERR_SRC_DIR/err.conf" ]]; then
      cp -f "$_ERR_SRC_DIR/err.conf" "$f" 2>/dev/null || return 1
    else
      : > "$f" || return 1
    fi
    [[ -r "$old" ]] || return 0
    kv=$(zsh -f -c '
      source "$1" 2>/dev/null
      [[ -n "${ERR_QUICK_THINKING:-}" && "$ERR_QUICK_THINKING" != default ]] && print -r -- "thinking=$ERR_QUICK_THINKING"
      [[ -n "${ERR_QUICK_TEMP:-}" ]] && print -r -- "temperature=$ERR_QUICK_TEMP"
      [[ -n "${ERR_QUICK_MAX_TOKENS:-}" ]] && print -r -- "max_tokens=$ERR_QUICK_MAX_TOKENS"
      [[ -n "${ERR_QUICK_SYSTEM_PROMPT:-}" ]] && print -r -- "chat_system_prompt=$ERR_QUICK_SYSTEM_PROMPT"
      [[ -n "${ERR_QUICK_MOE_CACHE:-}" ]] && print -r -- "moe_cache_gib=$ERR_QUICK_MOE_CACHE"
      local fl
      for fl in "${ERR_CHAT_FLAGS[@]}"; do [[ -n "$fl" ]] && print -r -- "chat_flag=$fl"; done
      for fl in "${ERR_SERVER_FLAGS[@]}"; do [[ -n "$fl" ]] && print -r -- "server_flag=$fl"; done
    ' _ "$old" 2>/dev/null)
    [[ -z "$kv" ]] && return 0
    for line in ${(f)kv}; do
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in
        chat_flag|server_flag) print -r -- "$k = $v" >> "$f" ;;
        *) _err_conf_set "$k" "$v" ;;
      esac
    done
    print -u2 "err: config is now $f (old config.zsh left in place)"
  }

  # Load the file into the variables the launch path already uses, so nothing
  # downstream changes. Repeated flag lines rebuild the arrays.
  _err_load_config() {
    _err_conf_seed
    local f; f=$(_err_conf_path)
    ERR_QUICK_THINKING="default"
    ERR_QUICK_TEMP=""; ERR_QUICK_MAX_TOKENS=""
    ERR_QUICK_SYSTEM_PROMPT=""; ERR_QUICK_MOE_CACHE=""
    typeset -ga ERR_CHAT_FLAGS=( --max-tokens 2048 --temperature 0.7 )
    typeset -ga ERR_SERVER_FLAGS=()
    if [[ -r "$f" ]]; then
      local line k v
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"; v="${line#*=}"
        k="${k//[[:space:]]/}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        case "$k" in
          thinking)           ERR_QUICK_THINKING="${v:-default}" ;;
          temperature)        ERR_QUICK_TEMP="$v" ;;
          max_tokens)         ERR_QUICK_MAX_TOKENS="$v" ;;
          chat_system_prompt) ERR_QUICK_SYSTEM_PROMPT="$v" ;;
          moe_cache_gib)      ERR_QUICK_MOE_CACHE="$v" ;;
          apc_enabled)        export APC_ENABLED="$v" ;;
          apc_disk_max_gb)    export APC_DISK_MAX_GB="$v" ;;
          chat_flag)          ERR_CHAT_FLAGS+=( ${=v} ) ;;
          server_flag)        ERR_SERVER_FLAGS+=( ${=v} ) ;;
        esac
      done < "$f"
    fi
    _err_apply_quick
  }

  _err_effective_backend() {
    local env_be file_be
    env_be="${ERR_BACKEND:-}"
    file_be="$(_err_conf_get backend)"
    if [[ -n "$env_be" ]]; then
      print -r -- "$env_be${file_be:+  (ERR_BACKEND overrides err.conf: $file_be)}"
    else
      print -r -- "${file_be:-fm}"
    fi
  }

  # Point the explain layer at a model: the Apple on-device model runs on `fm`
  # (or Private Cloud Compute), every HF repo runs on the :11500 server.
  _err_point_backend_at() {
    local model="$1" cur
    if [[ "$model" == "$_ERR_FM_ID" ]]; then
      cur=$(_err_conf_get backend)
      [[ "$cur" == pcc ]] || _err_conf_set backend fm
    else
      _err_conf_set backend mlx
    fi
    # A stray exported ERR_BACKEND beats the file, and that is invisible unless
    # we say so: the user changes the setting, sees it "applied", and err keeps
    # answering from the old backend.
    if [[ -n "${ERR_BACKEND:-}" ]]; then
      print -u2 "err: warning: this shell exports ERR_BACKEND=$ERR_BACKEND, which overrides"
      print -u2 "     err.conf. Run 'unset ERR_BACKEND' (or start a new shell)."
    fi
  }

  # One renderer for the submenus, with err's look: `arr //` on the cursor
  # row, the rest indented to match, one dim footer line, no title (the rows
  # are the commands, so a heading would only repeat the first word).
  #
  # No dialog toolkit: this is the whole menu. One footer line carries the
  # keys, so the hint text is err's, not a dependency's.
  #
  #   _err_pick [--multi] [--header text] label...
  #
  # Rows are arguments (the keyboard has to be the terminal); painting goes to
  # /dev/tty and only the chosen label(s) go to stdout, because callers capture
  # stdout (`pick=$(_err_pick ...)`). Esc is a plain cancel, never a fall-through.
  _err_pick() {
    local multi=0 header=""
    while (( $# )); do
      case "$1" in
        --multi)  multi=1; shift ;;
        --header) header="${2:-}"; shift 2 ;;
        *) break ;;
      esac
    done
    local -a rows=( "$@" )
    local footer='←↓↑→ navigate • esc return • enter submit'
    (( multi )) && footer='←↓↑→ navigate • space mark • enter submit • esc return'

    # Test seam: a pty with nobody typing would block forever. Dump the rows
    # and cancel, which is what a caller off a terminal sees.
    if [[ -n "${ERR_PICK_DUMP:-}" ]]; then
      [[ -n "$header" ]] && printf '%s\n' "$header" >&2
      (( ${#rows[@]} )) && printf '%s\n' "${rows[@]}" >&2
      return 1
    fi

    # Paint on stderr and read the keyboard from stdin: the caller captures
    # stdout, so the frame must not go there, and `read -k`
    # only puts the terminal into raw mode when stdin *is* the terminal — an
    # fd opened separately for /dev/tty gets keys only after Enter.
    #
    # No terminal (a pipe, a script, CI): print the rows so the menu is
    # visible, then abort. A picker that cannot render must never loop.
    if [[ ! -t 0 || ! -t 2 ]] || (( ${#rows[@]} == 0 )); then
      (( ${#rows[@]} )) && printf '%s\n' "${rows[@]}" >&2
      return 1
    fi

    local n=${#rows[@]} cursor=0 scroll=0 drawn=0 nlines=0
    local term_lines width
    read -r term_lines width <<< "$(_err_term_size)"
    # vis rows + one footer line must fit, or the repaint scrolls the screen.
    local vis=$(( term_lines - 4 ))   # rows + blank + footer must fit
    (( vis < 3 )) && vis=3
    (( vis > n )) && vis=n
    typeset -A marked=()

    _pick_scroll() {
      local max=$(( n - vis ))
      (( max < 0 )) && max=0
      (( scroll > max )) && scroll=$max
      if (( cursor < scroll )); then
        scroll=$cursor
      elif (( cursor >= scroll + vis )); then
        scroll=$(( cursor - vis + 1 ))
      fi
      (( scroll < 0 )) && scroll=0
    }
    _pick_clear() {
      if (( drawn )); then
        print -u2 -n -- "\033[${nlines}A\033[J"
        drawn=0
      fi
      print -u2 -n -- $'\e[?25h'
    }
    _pick_render() {
      print -u2 -n -- $'\e[?25l'
      (( drawn )) && print -u2 -n -- "\033[${nlines}A\033[J"
      local -a out=()
      if [[ -n "$header" ]]; then
        local first=1 hline
        for hline in "${(@f)header}"; do
          hline="${hline:0:$(( width - 1 ))}"
          if (( first )); then
            out+=( $'\e[1;35m'"$hline"$'\e[0m' )
            first=0
          else
            out+=( "$hline" )
          fi
        done
        # The help menu's header is a block (version, "Available commands:",
        # the typed-only rows). Keep one blank line before the pickable rows.
        [[ "$header" == *$'\n'* ]] && out+=( '' )
      fi
      local end=$(( scroll + vis )) i text pref
      (( end > n )) && end=n
      for (( i=scroll; i<end; i++ )); do
        text="${rows[$((i+1))]}"
        if (( i == cursor )); then
          (( multi && ${marked[$((i+1))]:-0} )) \
            && out+=( $'\e[1;32marr // '"$text"$'\e[0m' ) \
            || out+=( $'\e[1;36marr // '"$text"$'\e[0m' )
        else
          if (( multi && ${marked[$((i+1))]:-0} )); then pref=$'\e[1;32m*      '
          else pref='       '
          fi
          out+=( "$pref$text"$'\e[0m' )
        fi
      done
      out+=( '' )
      out+=( $'\e[2m'"${footer:0:$(( width - 1 ))}"$'\e[0m' )
      nlines=0
      local line
      for line in "${out[@]}"; do
        print -u2 -n -- "$line\033[K\n"
        (( nlines++ ))
      done
      drawn=1
    }

    local key seq third i
    _pick_render
    while true; do
      read -s -k 1 key || break
      case "$key" in
        $'\r'|$'\n')
          _pick_clear
          if (( multi )); then
            local -a picked=()
            for (( i=1; i<=n; i++ )); do
              (( ${marked[$i]:-0} )) && picked+=( "${rows[$i]}" )
            done
            (( ${#picked[@]} )) || return 1
            printf '%s\n' "${picked[@]}"
          else
            print -r -- "${rows[$((cursor+1))]}"
          fi
          return 0 ;;
        ' ')
          (( multi )) && (( marked[$((cursor+1))] = ! ${marked[$((cursor+1))]:-0} )) ;;
        $'\e')
          # An arrow key is ESC [ A/B, a plain ESC is the cancel.
          seq=""
          read -s -t 0.05 -k 1 seq
          if [[ "$seq" == ('['|'O') ]]; then
            third=""
            read -s -t 0.05 -k 1 third
            local tail=""
            case "$third" in
              A) (( cursor > 0 )) && (( cursor-- )) ;;
              B) (( cursor < n - 1 )) && (( cursor++ )) ;;
              # PgUp/PgDn (5~/6~) page, Home/End (1~/4~/H/F) jump.
              5|6|1|4)
                read -s -t 0.05 -k 1 tail
                case "$third$tail" in
                  5~) (( cursor -= vis - 1 )) ;;
                  6~) (( cursor += vis - 1 )) ;;
                  1~) cursor=0 ;;
                  4~) cursor=$(( n - 1 )) ;;
                esac
                (( cursor < 0 )) && cursor=0
                (( cursor >= n )) && cursor=$(( n - 1 )) ;;
              H) cursor=0 ;;
              F) cursor=$(( n - 1 )) ;;
            esac
            _pick_scroll
          else
            break
          fi ;;
        k|K) (( cursor > 0 )) && (( cursor-- )); _pick_scroll ;;
        j|J) (( cursor < n - 1 )) && (( cursor++ )); _pick_scroll ;;
        a|A)
          if (( multi )); then
            local all=1
            for (( i=1; i<=n; i++ )); do (( ${marked[$i]:-0} )) || all=0; done
            for (( i=1; i<=n; i++ )); do
              if (( all )); then marked[$i]=0; else marked[$i]=1; fi
            done
          fi ;;
      esac
      _pick_render
    done
    _pick_clear
    return 1
  }

  # Human label for a selectable row. The Apple model gets a description; HF
  # repos are already readable. Both markers below are two columns wide, so the
  # rows line up under the 7-column `arr // ` cursor (★ and friends are
  # double-width and visibly shift the list).
  _err_row_label() {
    if [[ "$1" == "$_ERR_FM_ID" ]]; then print -r -- "$_ERR_FM_LABEL"
    else print -r -- "$1"; fi
  }

  # Live terminal size, as "lines cols". $LINES/$COLUMNS are fixed when the
  # shell starts, so after a resize a repainting menu computes a frame taller
  # than the window — it draws off the bottom and the list looks unscrollable.
  _err_term_size() {
    local size="" lines cols
    size=$(stty size < /dev/tty 2>/dev/null)
    lines="${size%% *}"
    cols="${size##* }"
    [[ "$lines" == <-> ]] || lines=${LINES:-24}
    [[ "$cols" == <-> ]] || cols=${COLUMNS:-80}
    (( lines < 8 )) && lines=24
    (( cols < 40 )) && cols=80
    print -r -- "$lines $cols"
  }

  # Pick one row, then translate the label through _ERR_PICK_MAP. The callers
  # build that map so rows can stay the command a human would type while the
  # engine gets back the model id.
  _err_pick_map_pick() {
    local choice
    choice=$(_err_pick "$@") || return 1
    print -r -- "${_ERR_PICK_MAP[$choice]:-$choice}"
  }

  # Installed models, offered as *commands*: one row = the exact line you
  # would type. No title row — the rows already name the verb.
  _err_pick_installed() {  # header (unused), verb (default run), include apple-fm (default 1), exclude
    local verb="${2:-run}" with_fm="${3:-1}" exclude="${4:-}" id label
    local -a ids=( ${(f)"$(_err_installed_ids)"} )
    ids=( ${ids:#} )
    # A swap menu must not offer the model that is already serving: picking it
    # is a no-op that still prints a stop/start dance.
    if [[ -n "$exclude" ]]; then
      local -a kept=()
      for id in "${ids[@]}"; do
        [[ "$id" == "$exclude" ]] || kept+=( "$id" )
      done
      ids=( "${kept[@]}" )
    fi
    # `err run` puts the model served last at the top: Enter on the first row is
    # the common case, and it is usually the model you were just running.
    if [[ "$verb" == run ]]; then
      local last; last=$(_err_last_model)
      if [[ -n "$last" ]] && (( ${ids[(Ie)$last]:-0} )); then
        local -a reordered=( "$last" )
        for id in "${ids[@]}"; do
          [[ "$id" == "$last" ]] || reordered+=( "$id" )
        done
        ids=( "${reordered[@]}" )
      fi
    fi
    # The Apple model is a backend, not a repo: last, so the MLX repos a user
    # actually runs stay in front of it.
    local -a all=( "${ids[@]}" )
    (( with_fm )) && [[ "$exclude" != "$_ERR_FM_ID" ]] && all=( "${ids[@]}" "$_ERR_FM_ID" )
    if (( ! ${#all[@]} )); then
      if [[ -n "$exclude" ]]; then
        print -u2 "err: no other model installed — get one with 'err download'"
      else
        print -u2 "err: no models installed — try 'err download'"
      fi
      return 1
    fi
    _ERR_PICK_MAP=()
    local -a lines=()
    for id in "${all[@]}"; do
      label="err $verb $(_err_row_label "$id")"
      lines+=( "$label" )
      _ERR_PICK_MAP[$label]="$id"
    done
    _err_pick_map_pick "${lines[@]}"
  }

  # Curated catalog rows this Mac can host, labelled by title.
  _err_pick_catalog() {  # header (unused)
    local ram_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
    _ERR_PICK_MAP=()
    local -a lines=()
    local tier tname title ids tags desc firstid label size
    while IFS=$'\x1f' read -r tier tname title ids tags desc; do
      [[ -z "$ids" ]] && continue
      firstid="${ids%% & *}"
      # Already on disk: a download row would only re-fetch it. The free-text
      # row below stays, so a model that is not in the curated list is still
      # reachable.
      _err_model_present "$firstid" && continue
      # A size answers "how big is this download?" before you commit to it.
      size=$(_err_model_size "$firstid")
      label="err download $firstid${size:+  ($size)}"
      lines+=( "$label" )
      _ERR_PICK_MAP[$label]="$firstid"
    done < <(_err_catalog_rows_for_ram "$ram_gb" "$curated_file")
    # Anything not in the catalog: type its repo id, so `err download` never
    # needs a second invocation with an argument.
    label="err download Hugging Face ID"
    lines+=( "$label" )
    _ERR_PICK_MAP[$label]="__hf_id__"
    _err_pick_map_pick "${lines[@]}"
  }

  # With no model id: keep the default/last one if it is installed, else ask.
  _err_pick_default_first() {   # header, verb
    local header="$1" verb="${2:-run}" m
    for m in $(_err_default_model) $(_err_last_model); do
      [[ -z "$m" ]] && continue
      [[ "$m" == "$_ERR_FM_ID" ]] && { print -r -- "$m"; return 0 }
      _err_model_supported "$m" "$hub_dir" && { print -r -- "$m"; return 0 }
    done
    _err_pick_installed "$header" "$verb"
  }

  _err_headless_run() {
    local model="${1:-}"
    if [[ -z "$model" ]]; then
      # `err run` with nothing to run is a status question when a model is
      # already serving: say so instead of opening a picker that would only
      # offer what is already up (or a different model, which is `err swap`).
      local rpid rport rcur
      if [[ -n "$(_err_running_model)" ]]; then
        read -r rpid rport rcur <<< "$(_err_running_model)"
        _err_say "$rcur already running"
        _err_note_last_model "$rcur"
        return 0
      fi
      model=$(_err_pick_installed "err run" run) || return 1
    fi
    # After the pick, not before: the Apple model is a backend, not a repo, and
    # a pick of it must never fall through to a Hugging Face download.
    if [[ "$model" == "$_ERR_FM_ID" ]]; then
      _err_fm_start
      return $?
    fi
    # Fetch uncached weights before choosing a backend: the streaming-MoE
    # compatibility check reads the cached config.json, so a fresh model has to
    # be on disk first. snapshot_download does not load the model into RAM.
    if _err_model_supported "$model" "$hub_dir" \
       && [[ ! -d "$hub_dir/models--${model//\//--}/snapshots" ]]; then
      print -u2 "err: downloading $model first (no local snapshot)…"
      _err_snapshot_download "$model" || {
        print -u2 "err: download failed for $model"
        return 1
      }
    fi
    # Fast path: the requested model is already serving.
    if [[ -n "$(_err_running_model)" ]]; then
      local pid port cur
      read -r pid port cur <<< "$(_err_running_model)"
      if [[ "$cur" == "$model" ]]; then
        _err_say "$model already running"
        _err_note_last_model "$model"
        return 0
      fi
      _err_status_set "stopping $cur on http://127.0.0.1:$port"
      kill "$pid" 2>/dev/null
      local i
      for i in {1..40}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
    fi
    _err_headless_launch "$model"
    local rc=$?
    (( rc == 0 )) && _err_note_last_model "$model"
    return $rc
  }


  _err_headless_stop() {
    local want="${1:-}"
    # err stop            -> every err server (11500–11509); the common case
    # err stop <model>    -> that model, wherever it runs
    # err stop --all      -> same as bare `err stop`
    [[ -z "$want" ]] && want="--all"
    if [[ "$want" == "$_ERR_FM_ID" ]]; then
      _err_fm_stop || _err_say "the Apple Foundation Model is not running"
      return 0
    fi
    if [[ "$want" == "--all" ]]; then
      _err_fm_stop >/dev/null 2>&1
      local n=0 pid port model
      while IFS=$'\t' read -r pid port model; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && { _err_say "stopped $model (:$port)"; (( n++ )); }
      done < <(_err_running)
      (( n == 0 )) && _err_say "nothing is running"
      return 0
    fi
    if [[ -n "$want" ]]; then
      local n=0 pid port model
      while IFS=$'\t' read -r pid port model; do
        if [[ "$model" == "$want" ]]; then
          kill "$pid" 2>/dev/null && { print "err: stopped $model (:$port)"; (( n++ )); }
        fi
      done < <(_err_running)
      if (( n == 0 )); then
        print -u2 "err: no running server for '$want'"
        return 1
      fi
      return 0
    fi
    if [[ -n "$(_err_running_model)" ]]; then
      local pid port cur
      read -r pid port cur <<< "$(_err_running_model)"
      kill "$pid" 2>/dev/null && print "err: stopped $cur (pid $pid)"
      return 0
    fi
    print "err: nothing running on :11500"
    return 0
  }

  # err switch [model] — stop whatever serves :11500 and start another, and
  # KEEP that choice: a switch is a move, not a one-off. The pick is written to
  # default-model as well, otherwise the next err call would fall back to the
  # model you just switched away from (mlx_model_id reads last-model, and the
  # menus/`err ensure` read default-model).
  _err_headless_switch() {
    # There is nothing to swap *from* when nothing is running: starting the
    # first model is `err run`.
    if [[ -z "$(_err_running_model)" ]]; then
      _err_say "nothing is running — start one with 'err run <model>'"
      return 1
    fi
    local model="${1:-}" cur="" pid port
    read -r pid port cur <<< "$(_err_running_model)"
    if [[ -z "$model" ]]; then
      # The model that is already serving is not a swap target.
      model=$(_err_pick_installed "err swap" swap 1 "$cur") || return 1
    fi
    _err_headless_run "$model" || return $?
    print -r -- "$model" > "$state_dir/default-model"
    _err_point_backend_at "$model"
  }

  # Wait until :11500 answers /v1/models. $1 = max seconds (default 600). A
  # model another shell launched keeps loading; this lets a second call wait for
  # it instead of trying to launch a second copy.
  # True when the server on $1 can answer a chat request, not merely listen.
  # mlx-vlm serves /v1/models while its startup preload still runs and 503s the
  # first chat with `model_loading`, so readiness must come from /health's
  # model_ready. Servers without /health (fm, another OpenAI server) fall back
  # to plain liveness.
  _err_server_ready() {
    local port="$1" body
    if body=$(curl -fs --max-time 1 "http://127.0.0.1:$port/health" 2>/dev/null); then
      case "$body" in
        *'"model_ready":false'*|*'"model_ready": false'*|*'"preload_in_progress":true'*) return 1 ;;
      esac
      return 0
    fi
    curl -fs -o /dev/null --max-time 1 "http://127.0.0.1:$port/v1/models" 2>/dev/null
  }

  _err_wait_health() {
    local timeout="${1:-600}" model="${2:-the model}" port="${3:-11500}"
    local url="http://127.0.0.1:$port" deadline=$(( timeout * 5 ))
    _err_status_set "loading $model on $url"
    local spin=0 i
    if [[ -t 2 ]]; then
      spin=1
      _err_spin_tick 1 "loading $model on $url"
    fi
    for i in {1..$deadline}; do
      (( spin )) && _err_spin_tick "$i" "loading $model on $url"
      if _err_server_ready "$port"; then
        (( spin )) && printf '\r\033[K' >&2
        _err_say "running: $model on $url"
        return 0
      fi
      sleep 0.2
    done
    (( spin )) && printf '\r\033[K' >&2
    return 1
  }

  # err ensure [model] — hidden verb, called by err.py. Make :11500 serve
  # `model` right now so asking a question never needs a separate `err run`:
  #   nothing there        -> start it
  #   another model there  -> stop every err server, start this one on :11500
  #   this model there     -> wait for it to finish loading, change nothing
  # Model comes from default-model (then last-model) when the arg is omitted.
  _err_headless_ensure() {
    local model="${1:-}" pid port cur unsupported
    [[ -z "$model" ]] && model=$(_err_default_model)
    if [[ -z "$model" ]]; then
      print -u2 "err: no model selected — pick one with: err run <model>"
      return 1
    fi
    # fm's sentinels are not HuggingFace repos. Without this, `ensure system`
    # falls through to snapshot_download and 404s on api/models/system — the
    # exact repo-not-found failure the fm/MLX split exists to prevent.
    if [[ "$model" == "$_ERR_FM_ID" || "$model" == (system|pcc) ]]; then
      print -u2 "err: $model is the on-device fm backend, not an MLX model on :11500"
      print -u2 "err: choose an MLX model with: err swap <model>"
      return 1
    fi
    # Validate, and fetch missing weights, BEFORE stopping anything: a bad or
    # unavailable model must not take down the server that answers right now.
    if unsupported=$(_err_model_unsupported_reason "$model" "$hub_dir"); then
      print -u2 "err: $model can't be served — $unsupported."
      print -u2 "MLX-quantized repos run directly (e.g. mlx-community/…-4bit)."
      return 1
    fi
    if [[ ! -d "$hub_dir/models--${model//\//--}/snapshots" ]]; then
      print -u2 "err: downloading $model first (no local snapshot)…"
      _err_snapshot_download "$model" || {
        print -u2 "err: download failed for $model — the running server is untouched"
        return 1
      }
    fi
    cur=""
    if [[ -n "$(_err_running_model)" ]]; then
      read -r pid port cur <<< "$(_err_running_model)"
    fi
    if [[ -n "$cur" && "$cur" == "$model" ]]; then
      # Right model, not answering yet: it is still loading. Never kill and
      # relaunch it — that would restart a several-minute load. _err_wait_health
      # prints the same starting/ready line as a fresh launch.
      if _err_wait_health 600 "$model" 11500; then
        _err_note_last_model "$model"
        return 0
      fi
      print -u2 "err: $model never answered on :11500 — see $log_dir"
      return 1
    fi
    if [[ -n "$(_err_running)" ]]; then
      print -u2 "Stopping ${cur:-the running model} so :11500 can serve $model"
      _err_stop_all >/dev/null 2>&1
      local i
      for i in {1..40}; do
        _err_port_free 11500 && break
        sleep 0.2
      done
    fi
    _err_headless_run "$model"
  }


  # err remove [model]... — delete weights from disk. Never touches config.
  _err_headless_remove() {
    local -a want=( "$@" )
    if (( ! ${#want} )); then
      local -a ids=( ${(f)"$(_err_headless_list)"} )
      ids=( ${ids:#} )
      if (( ! ${#ids} )); then print "err: nothing installed"; return 0; fi
      local picked
      local id row
      local -a rows=()
      _ERR_PICK_MAP=()
      for id in "${ids[@]}"; do
        rows+=( "err remove $id" )
        _ERR_PICK_MAP["err remove $id"]="$id"
      done
      picked=$(_err_pick --multi "${rows[@]}") || return 1
      [[ -z "$picked" ]] && return 1
      for row in ${(f)picked}; do
        want+=( "${_ERR_PICK_MAP[$row]:-$row}" )
      done
    fi

    # Validate BEFORE asking: confirming a delete for a model that isn't there
    # is the kind of prompt that trains people to answer without reading.
    local -a present=() absent=()
    local model folder rc=0
    for model in "${want[@]}"; do
      folder="$hub_dir/models--${model//\//--}"
      if [[ -d "$folder" ]]; then present+=( "$model" ); else absent+=( "$model" ); fi
    done
    for model in "${absent[@]}"; do
      print -u2 "err: not installed: $model"
      rc=1
    done
    (( ${#present[@]} )) || return $rc

    print "err: this deletes weights from $hub_dir"
    printf '  %s\n' "${present[@]}"
    _err_confirm "Delete ${#present} model(s) permanently?" || { print "aborted"; return 1; }

    for model in "${present[@]}"; do
      folder="$hub_dir/models--${model//\//--}"
      if rm -rf "$folder" 2>/dev/null; then
        print "  ✓ removed $model"
        _err_purge_orphan_blobs "$hub_dir" 2>/dev/null
      else
        print -u2 "  err: could not remove $model"
        rc=1
      fi
    done
    return $rc
  }


  # err doctor — one pass/fail line per subsystem. The point is to convert
  # "it doesn't work" into a named failing part, so nobody has to guess whether
  # the backend, the launcher, the server or the config is at fault.
  _err_headless_doctor() {
    local problems=0 warnings=0
    local row() {  # $1 status(ok|warn|fail), $2 name, $3 detail, $4 fix
      printf '  %-5s %-18s %s\n' "$1" "$2" "$3"
      [[ -n "${4:-}" ]] && printf '        %-18s fix: %s\n' "" "$4"
    }

    # 1. err.conf
    local conf; conf=$(_err_conf_path)
    if [[ -r "$conf" ]]; then
      local be sug auto
      be=$(_err_effective_backend)
      sug=$(_err_conf_get suggest); sug=${sug:-history}
      auto=$(_err_conf_get mlx_autostart); auto=${auto:-on}
      case "$sug" in
        history|ask|off) row ok conf "backend=$be suggest=$sug autostart=$auto" ;;
        *) row fail conf "unknown suggest=$sug" "set suggest = history|ask|off" ;;
      esac
      [[ -n "${ERR_BACKEND:-}" ]] && {
        row warn conf "ERR_BACKEND=$ERR_BACKEND overrides the file" "unset ERR_BACKEND"
        (( warnings++ ))
      }
    else
      row fail conf "not readable: $conf" "re-run install.sh"
      (( problems++ ))
    fi

    # 2. explain layer
    if command -v python3 >/dev/null 2>&1; then
      local pv; pv=$(python3 -V 2>&1 | awk '{print $2}')
      if python3 -c "import sys; sys.path.insert(0, '$_ERR_SRC_DIR'); import err" 2>/dev/null; then
        row ok python "python3 $pv, err.py imports"
      else
        row fail python "python3 $pv, err.py fails to import" "python3 -c 'import err' in $_ERR_SRC_DIR"
        (( problems++ ))
      fi
    else
      row fail python "python3 not found" "install the CLT or python.org python"
      (( problems++ ))
    fi

    # 3. the prompts actually in force. A hand-edited prompt is otherwise
    # invisible: every answer degrades and nothing says why. err.py owns the
    # precedence (explain_system_prompt -> legacy system_prompt -> builtin), so
    # ask it rather than re-implementing that in zsh.
    local pkind p_out p_origin p_text
    for pkind in explain question; do
      if p_out=$(python3 "$_ERR_SRC_DIR/err.py" --prompt "$pkind" 2>/dev/null) \
          && [[ -n "$p_out" ]]; then
        p_origin="${p_out%%$'\t'*}"; p_text="${p_out#*$'\t'}"
        (( ${#p_text} > 58 )) && p_text="${p_text[1,58]}…"
        row ok "prompt-$pkind" "$p_origin — $p_text"
      else
        row warn "prompt-$pkind" "could not read the effective prompt" \
          "python3 $_ERR_SRC_DIR/err.py --prompt $pkind"
        (( warnings++ ))
      fi
    done

    # 4. launcher freshness (the shell that called us exported its load time)
    local lt="${_ERR_LOADED_AT:-}" mt
    mt=$(/usr/bin/stat -f %m "$_ERR_SRC_DIR/err-launcher.zsh" 2>/dev/null)
    if [[ -n "$lt" && -n "$mt" ]] && (( mt > lt )); then
      row warn launcher "changed on disk after this shell loaded it" "reload"
      (( warnings++ ))
    else
      row ok launcher "current in this shell"
    fi

    # 5. state
    if [[ -w "$state_dir" ]]; then
      local ns; ns=$(ls -1 "$state_dir/sessions" 2>/dev/null | wc -l | tr -d ' ')
      row ok state "$state_dir (${ns} session(s))"
    else
      row fail state "not writable: $state_dir" "chmod u+w $state_dir"
      (( problems++ ))
    fi
    local def; def=$(_err_default_model)
    if [[ -z "$def" ]]; then
      row warn model "no model has been run yet" "err run <model>"
      (( warnings++ ))
    elif [[ "$def" == "$_ERR_FM_ID" ]]; then
      row ok default "apple-fm (on-device)"
    elif [[ -n "$(_err_conf_get mlx_model)${ERR_MLX_MODEL:-}" ]]; then
      row ok default "$def (remote server)"
    elif [[ -d "$hub_dir/models--${def//\//--}" ]]; then
      row ok default "$def (downloaded)"
    else
      row fail default "$def is not on disk" "err download $def"
      (( problems++ ))
    fi

    # 6. the backend's server
    case "$(_err_effective_backend)" in
      mlx*)
        local base; base=$(_err_conf_get mlx_base_url); base=${base:-http://127.0.0.1:11500}
        if curl -fs -o /dev/null --max-time 2 "$base/v1/models" 2>/dev/null; then
          local mid; mid=$(cat "$state_dir/last-model" 2>/dev/null | tr -d '[:space:]')
          row ok mlx-server "$base reachable (${mid:-model unknown})"
        else
          local auto; auto=$(_err_conf_get mlx_autostart); auto=${auto:-on}
          if [[ "$auto" == on ]]; then
            row warn mlx-server "$base not reachable — will autostart on next ask"
            (( warnings++ ))
          else
            row fail mlx-server "$base not reachable" "err run <model>"
            (( problems++ ))
          fi
        fi
        ;;
      *)
        local fmp; fmp=$(_err_fm_port)
        if _err_fm_running >/dev/null; then
          row ok fm-server ":$fmp reachable"
        elif command -v fm >/dev/null 2>&1; then
          row warn fm-server ":$fmp not running — starts on next ask" ""
          (( warnings++ ))
        else
          row fail fm-server "the fm CLI is missing (needs macOS 26+)" "or set backend = mlx"
          (( problems++ ))
        fi
        ;;
    esac

    # 7. tools the model manager needs
    local -a missing=(); local t
    for t in uv uvx mlx_vlm.server; do
      command -v "$t" >/dev/null 2>&1 || missing+=( "$t" )
    done
    if (( ${#missing} )); then
      row warn tools "missing: ${missing[*]}" "re-run install.sh"
      (( warnings++ ))
    else
      row ok tools "uv, uvx, mlx_vlm.server"
    fi

    # 8. disk
    local apc_kb cap_gb total_gb
    local apc_dir="${APC_DISK_PATH:-$state_dir/apc}"
    apc_kb=$(du -sk "$apc_dir" 2>/dev/null | awk '{print $1}'); apc_kb=${apc_kb:-0}
    cap_gb="${ERR_APC_TOTAL_GB:-6}"
    total_gb=$(( apc_kb / 1024 / 1024 ))
    if (( total_gb > cap_gb )); then
      row warn disk "prefix cache ${total_gb} GiB at $apc_dir (cap ${cap_gb} GiB)" "err clean --apc"
      (( warnings++ ))
    else
      row ok disk "prefix cache ${total_gb} GiB (cap ${cap_gb} GiB)"
    fi

    # 9. leftovers from crashed invocations
    local stale; stale=$(ls -1 "$state_dir"/run/*(N) 2>/dev/null | wc -l | tr -d ' ')
    if (( stale > 50 )); then
      row warn temp "$stale scratch files in $state_dir/run" "rm -f $state_dir/run/*"
      (( warnings++ ))
    else
      row ok temp "no scratch-file buildup"
    fi

    print ""
    if (( problems )); then
      print "err doctor: $problems problem(s), $warnings warning(s)"
      return 1
    fi
    print "err doctor: healthy ($warnings warning(s))"
    return 0
  }

  # err uninstall — stop servers, unwire ~/.zshrc, report what is left behind.
  _err_headless_uninstall() {
    print "This stops err's servers and removes its line from ~/.zshrc."
    print "Models, config and logs are NOT deleted (see 'err cache')."
    _err_confirm "Uninstall err?" || { print "aborted"; return 1; }
    local pid port model
    while IFS=$'\t' read -r pid port model; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && print "  ✓ stopped $model (:$port)"
    done < <(_err_running)
    local rc="$HOME/.zshrc" tmp
    if [[ -r "$rc" ]] && grep -q 'err-launcher.zsh' "$rc" 2>/dev/null; then
      tmp=$(mktemp)
      grep -v 'err-launcher.zsh' "$rc" > "$tmp"
      mv "$tmp" "$rc"
      print "  ✓ removed the launcher line from $rc"
    else
      print "  · no launcher line found in $rc"
    fi
    print ""
    print "Done. To remove the code itself:"
    print "  rm -rf \"$_ERR_SRC_DIR\""
    print "Open a new terminal afterwards."
  }


  # Installed model ids, sorted, byte order pinned: the raw material every
  # picker and `err list` share. Deliberately *not* the `err list` verb —
  # that opens a picker on a terminal, so calling it from a picker recurses.
  # Is this repo's snapshot already on disk? A directory is enough: the hub
  # only creates `snapshots/` after a successful snapshot_download.
  _err_model_present() {
    [[ -n "${1:-}" && -d "$hub_dir/models--${1//\//--}/snapshots" ]]
  }

  _err_installed_ids() {
    local all="${1:-0}" m id
    local -a models=( "$hub_dir"/models--*(N/) ) ids=()
    for m in "${models[@]}"; do
      id="${${m:t}#models--}"; id="${id//--//}"
      # GGUF repos can never be served by mlx-vlm; keep them out of the list
      # (they stay reachable via `err list --all`).
      if (( all )) || _err_model_supported "$id" "$hub_dir"; then
        ids+=( "$id" )
      fi
    done
    # LC_ALL=C pins byte order so scripts see the same order on any machine
    # (zsh's (o) flag follows the locale and varies between hosts).
    (( ${#ids[@]} )) && printf '%s\n' "${ids[@]}" | LC_ALL=C sort
    return 0
  }

  _err_headless_list() {
    local json=0 all=0 arg
    for arg in "$@"; do
      case "$arg" in
        --json) json=1 ;;
        --all)  all=1 ;;   # include repos mlx-vlm cannot serve (e.g. GGUF)
        *) print -u2 "usage: err list [--json] [--all]"; return 2 ;;
      esac
    done
    # Always plain data: `err list` is a list. Details, running and swapping are
    # `err info` / `err run` / `err swap`.
    local -a ids=( ${(f)"$(_err_installed_ids $all)"} )
    ids=( ${ids:#} )
    if (( json )); then
      print -n '['
      local first=1 id
      for id in "${ids[@]}"; do
        (( first )) || print -n ','
        first=0
        print -n "\"$(_err_json_escape "$id")\""
      done
      print ']'
    else
      if [[ -t 0 && -t 1 && -t 2 ]] && (( ${#ids[@]} )); then
        # A look-only picker: one `arr //` cursor that moves up and down, but
        # Enter/Esc do nothing — the rows are the answer, not a choice. Piped
        # output stays bare ids, so scripts and --json clients are untouched.
        _err_pick "${ids[@]}" >/dev/null || true
      else
        (( ${#ids[@]} )) && printf '%s\n' "${ids[@]}"
      fi
    fi
    return 0
  }

  # Human size of a model's weights, symlinks followed (a hub model dir holds
  # `snapshots/…` links into `blobs/`, so a plain du under-reports it).
  _err_model_size() {
    local folder="$hub_dir/models--${1//\//--}" target kb
    target="$folder/snapshots"
    [[ -d "$target" ]] || target="$folder"
    [[ -d "$target" ]] || return 0
    kb=$(du -skL "$target" 2>/dev/null | awk '{print $1}')
    [[ -n "$kb" ]] && _err_fmt_bytes $(( kb * 1024 )) 2>/dev/null
  }

  # The MLX backend, read off uv's receipt — never by starting python: `err
  # info` must answer in milliseconds and work offline.
  _err_backend_label() {
    local receipt="$(uv tool dir 2>/dev/null)/mlx-vlm/uv-receipt.toml" ver
    if [[ -r "$receipt" ]]; then
      ver=$(grep -oE 'mlx-vlm==[0-9][^"]*' "$receipt" 2>/dev/null | head -1)
      ver="${ver#mlx-vlm==}"
    fi
    print -r -- "uv tool mlx-vlm${ver:+ $ver}"
  }

  # The one block `err info` shows: the three values an OpenAI client needs,
  # nothing else. The model id is the one thing worth colouring.
  _err_info_block() {  # model
    local model="$1" accent="" reset=""
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
      accent=$'\e[1;38;5;214m'; reset=$'\e[0m'
    fi
    print "Model:    ${accent}${model}${reset}"
    print "Base URL: http://localhost:11500/v1"
    print "API key:  none"
  }

  # ── cleanup ──────────────────────────────────────────────────────
  # Sizes are measured live: the number IS the reason to run this. Nothing here
  # can touch model weights — only regenerable state.
  _err_cleanup_path() {
    case "$1" in
      kv-cache) print -r -- "$state_dir/apc" ;;
      logs)     print -r -- "$log_dir" ;;
      sessions) print -r -- "$state_dir/sessions" ;;
      chats)    print -r -- "$chat_dir" ;;
    esac
  }

  _err_cleanup_size() {
    local kind="$1" p
    if [[ "$kind" == all ]]; then
      local total=0 k
      for k in kv-cache logs sessions chats; do
        p=$(_err_cleanup_path "$k")
        total=$(( total + $(_err_du_bytes "$p") ))
      done
      _err_fmt_bytes "$total"
      return 0
    fi
    p=$(_err_cleanup_path "$kind")
    [[ -e "$p" ]] || { print -r -- "0B"; return 0 }
    local n; n=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
    print -r -- "${n:-?}"
  }

  _err_headless_cleanup() {
    local kind choice what
    if (( $# )); then
      what="$1"
      case "$what" in
        kv-cache|logs|sessions|chats|all) ;;
        *) print -u2 "usage: err cleanup [kv-cache|logs|sessions|chats|all]"; return 2 ;;
      esac
    else
      local -a rows=()
      for kind in kv-cache logs sessions chats all; do
        rows+=( "err cleanup ${(r:10:)kind} $(_err_cleanup_size "$kind")" )
      done
      choice=$(_err_pick "${rows[@]}") || return 0
      [[ -z "$choice" ]] && return 0
      what="${${choice##*cleanup }%% *}"
    fi
    _err_confirm "Clear $what ($(_err_cleanup_size "$what"))?" || return 0
    if [[ "$what" == all ]]; then
      # One confirmation, then every regenerable cache in one pass.
      _err_clean_cmd "$state_dir" "$hub_dir" --apc --force
      _err_clean_cmd "$state_dir" "$hub_dir" --logs
      rm -rf "$(_err_cleanup_path sessions)" "$(_err_cleanup_path chats)"
      return 0
    fi
    case "$what" in
      # A live server holds APC files open: --force is only reachable after
      # the confirmation above.
      kv-cache) _err_clean_cmd "$state_dir" "$hub_dir" --apc --force ;;
      logs)     _err_clean_cmd "$state_dir" "$hub_dir" --logs ;;
      sessions|chats) rm -rf "$(_err_cleanup_path "$what")" ;;
    esac
    return 0
  }

  # `err config` — the one file, opened in your editor. No submenus.
  _err_headless_config() {
    local f; f=$(_err_conf_path)
    [[ -r "$f" ]] || { print -u2 "err: config not found: $f"; return 1; }
    # micro/nano before $VISUAL/$EDITOR: the file is short, and vim is a poor
    # first choice for someone who just wants to change a number.
    local ed; ed=$(_err_pick_editor)
    _err_say "$f"
    # micro offers to recover a stale backup on open, which turns `err config`
    # into a three-way prompt. Give this invocation a fresh backup dir and no
    # new backups: the config is short, and the file itself is the source.
    if [[ "${ed%% *}" == micro ]]; then
      local bdir rc
      bdir=$(mktemp -d "${TMPDIR:-/tmp}/err-micro.XXXXXX") || {
        "${=ed}" "$f"; return $?
      }
      "${=ed}" -backup false -backupdir "$bdir" "$f"
      rc=$?
      rm -rf "$bdir"
      return $rc
    fi
    "${=ed}" "$f"
  }

  # ── the menu ──────────────────────────────────────────────────────
  # The rows are the one definition of what err can do: the picker renders
  # them, and the non-interactive path prints exactly the same list. A test
  # (or `err | grep`) therefore sees the menu without a terminal.
  # One definition of the menu: "<command>|<description>". The picker aligns
  # the description in a column, the plain path prints the same pairs, and
  # nothing else knows the verb list.
  _err_help_specs() {
    print -r -- "err new|start a fresh session"
    print -r -- "err resume|resume a session"
    print -r -- "err run <model>|start a model on port 11500"
    print -r -- "err swap <model>|swap to another model"
    print -r -- "err info|what is running, with details"
    print -r -- "err stop|stop the running model"
    print -r -- "err list|list installed models"
    print -r -- "err download <model>|download model(s)"
    print -r -- "err remove <model>|remove model(s)"
    print -r -- "err config|edit the config file"
    print -r -- "err cleanup|clear cached state"
    print -r -- "err uninstall|remove err"
    print -r -- "err doctor|check the install"
  }

  # The part of the menu that is not pickable: the two row types you can only
  # type. They sit above the cursor's first row (`err new`), so ↑/↓ can never
  # land on a row that would have to be re-dispatched as a placeholder.
  _err_help_header() {
    local ver
    ver=$(<"$_ERR_SRC_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')
    print -r -- "err // ${ver:-?} // local MLX LLM runner"
    print -r -- ""
    print -r -- "Available commands:"
    printf '       %-22s %s\n' "err 'question'" "ask a question"
    printf '       %-22s %s\n' "err wtf" "ask to explain or correct your last command"
  }

  _err_help_rows() {
    local spec cmd desc
    _err_help_header
    print -r -- ""
    while IFS= read -r spec; do
      [[ -z "$spec" ]] && continue
      cmd="${spec%%|*}"; desc="${spec#*|}"
      printf '       %-22s %s\n' "$cmd" "$desc"
    done < <(_err_help_specs)
  }

  # Bare `err` / `err -h`. A pick returns "<verb>\t<rest>" on stdout and the
  # launcher re-dispatches it through `err`, never `eval`, so the menu cannot
  # drift from the typed command. Rows that need an argument open a picker
  # (models) or a text field (the question) instead of a placeholder to edit.
  # The pick has to leave the engine without owning its stdout: the launcher
  # passes a file and stdout stays the terminal, so the picker can paint on
  # stderr while the pick goes to stdout.
  _menu_emit() {  # line, out-file
    if [[ -n "${2:-}" ]]; then print -r -- "$1" > "$2"
    else print -r -- "$1"; fi
  }

  _err_help_menu() {
    local out="${1:-}" choice verb rest
    # No terminal: print the rows, which is what a script (and the tests) must
    # see (`err | cat` included). A picker that cannot render must never
    # fall into "ask again".
    if [[ ! -t 0 || ! -t 1 ]]; then
      _err_help_rows
      return 0
    fi
    local -A map=()
    local -a rows=() specs=( ${(f)"$(_err_help_specs)"} )
    local spec cmd desc
    for spec in "${specs[@]}"; do
      cmd="${spec%%|*}"; desc="${spec#*|}"
      rows+=( "$(printf '%-22s %s' "$cmd" "$desc")" )
      map[${rows[-1]}]="$cmd"
    done
    while true; do
      # The header carries the version and the typed-only rows; the picker
      # only ever moves over the selectable ones (first row: `err new`).
      choice=$(_err_pick --header "$(_err_help_header)" "${rows[@]}") \
        || return 1
      [[ -z "$choice" ]] && return 1
      cmd="${map[$choice]:-}"
      [[ -z "$cmd" ]] && continue
      case "$cmd" in
        "err run <model>"|"err swap <model>"|"err remove <model>")
          verb="${${cmd#err }%% *}"
          local pick
          # apple-fm ships with macOS and cannot be removed; swap never offers
          # the model that is already serving.
          local exclude="" running
          if [[ "$verb" == swap ]]; then
            running=$(_err_running_model)
            if [[ -n "$running" ]]; then
              local rpid rport rcur
              read -r rpid rport rcur <<< "$running"
              exclude="$rcur"
            fi
          fi
          pick=$(_err_pick_installed "err $verb" "$verb" \
            $([[ "$verb" == remove ]] && echo 0 || echo 1) "$exclude") || continue
          _menu_emit "$verb"$'\t'"$pick" "$out"; return 0 ;;
        "err download <model>")
          local pick
          pick=$(_err_pick_catalog "err download") || continue
          _menu_emit "download"$'\t'"$pick" "$out"; return 0 ;;
        *)
          rest="${cmd#err }"
          if [[ "$rest" == *' '* ]]; then
            _menu_emit "${rest%% *}"$'\t'"${rest#* }" "$out"
          else
            _menu_emit "$rest"$'\t' "$out"
          fi
          return 0 ;;
      esac
    done
  }

  # `err info` — what is serving :11500 right now. Nothing running: offer the
  # installed models, start the pick, then show the block for it.
  _err_headless_info() {
    local json=0 a
    for a in "$@"; do
      case "$a" in
        --json) json=1 ;;
        *) print -u2 "usage: err info [--json]"; return 2 ;;
      esac
    done
    # Read-only: never starts anything. Nothing running is a valid answer.
    if [[ -z "$(_err_running_model)" ]]; then
      (( json )) && { print 'null'; return 1; }
      _err_say "nothing is running — start one with 'err run <model>'"
      return 1
    fi
    local pid port model
    read -r pid port model <<< "$(_err_running_model)"
    if [[ -z "$model" ]]; then
      (( json )) && print 'null'
      print -u2 "err: nothing is running on :11500"
      return 1
    fi
    if (( json )); then
      printf '{"model":"%s","path":"%s","base_url":"http://localhost:11500/v1","backend":"%s"}\n' \
        "$(_err_json_escape "$model")" \
        "$(_err_json_escape "$hub_dir/models--${model//\//--}")" \
        "$(_err_json_escape "$(_err_backend_label)")"
      return 0
    fi
    _err_info_block "$model"
  }


  # Download one or more models. Reuses the shared loader, so
  # caching/verification behavior stays identical.
  _err_headless_download() {
    local -a want=( "$@" )
    if (( ! ${#want} )); then
      local picked
      picked=$(_err_pick_catalog "err download") || return 1
      want=( "$picked" )
    fi
    # `__hf_id__` is the catalog picker's "type an id" sentinel. It arrives as
    # an argument too — the help menu re-dispatches its pick as
    # `err download <value>` — so resolve it here, once, for every entry point.
    local i id
    for (( i=1; i<=${#want}; i++ )); do
      [[ "${want[$i]}" == "__hf_id__" ]] || continue
      id=$(_err_input 'Hugging Face ID (org/model): ') || return 1
      [[ -z "$id" ]] && return 1
      want[$i]="$id"
    done
    local model rc=0
    set -- "${want[@]}"
    for model in "$@"; do
      # Never re-download what is already on disk: the picker hides these, and
      # an explicit id gets the same answer instead of a useless re-fetch.
      if _err_model_present "$model"; then
        _err_say "$model already downloaded"
        continue
      fi
      print -u2 "err: downloading $model …"
      if _err_snapshot_download "$model"; then
        print -u2 "err: downloaded $model"
      else
        print -u2 "err: download failed for $model"
        rc=1
      fi
    done
    return $rc
  }


  # ---- CLI mode -------------------------------------------------
  # ``err <sub> [args]`` runs and exits. Servers started by `run` are
  # DETACHED — they must survive this shell exiting (the pi model_select hook
  # relies on it) — so we clear the EXIT trap, never add the pid to
  # _ERR_SESSION_PIDS, and disown it.
  # Every setting comes from the one file; loaded here so all the helpers that
  # read it (and `_err_apply_quick`) are defined.
  _err_load_config

  if (( $# == 0 )); then
    _err_help_rows
    return 0
  fi

  local _sub="$1"; shift
  trap - EXIT INT TERM HUP
  case "$_sub" in
      run|serve)  _err_headless_run      "$@" ;;
      switch|swap) _err_headless_switch  "$@" ;;
      # Hidden: err.py's autostart path (see _err_headless_ensure). Not in
      # _err_usage, not in the launcher's verb list, not for humans.
      ensure)     _err_headless_ensure   "$@" ;;
      remove|rm)  _err_headless_remove   "$@" ;;
      config)     _err_headless_config   "$@" ;;
      uninstall)  _err_headless_uninstall "$@" ;;
      doctor)     _err_headless_doctor    "$@" ;;
      stop)       _err_headless_stop     "$@" ;;
      list|ls)    _err_headless_list     "$@" ;;
      info)       _err_headless_info     "$@" ;;
      download)   _err_headless_download "$@" ;;
      version)    print "$(<"$_ERR_SRC_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')" ;;
      cleanup)    _err_headless_cleanup "$@" ;;
      # Hidden: the launcher's bare `err` / `-h` entry point.
      helpmenu)   _err_help_menu        "$@" ;;
      -h|--help)  _err_help_menu ;;
      *) print -u2 "err: unknown command '$_sub'"; print -u2 "     run 'err' to see the menu"; return 2 ;;
  esac
  return
}

_err_cleanup() {
  local pid
  for pid in "${_ERR_SESSION_PIDS[@]}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  [[ -n "$_ERR_STTY_SAVED" ]] && stty "$_ERR_STTY_SAVED" 2>/dev/null
}
trap _err_cleanup EXIT INT TERM HUP

_err_engine_main "$@"
