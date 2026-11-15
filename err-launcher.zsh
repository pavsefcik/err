#!/usr/bin/env zsh
# err 0.601 — shell shim: hooks, dispatch, per-shell facts.
# Add to ~/.zshrc:  source "/path/to/err-launcher.zsh"
#
# Two engines behind one command:
#   err.py          explain / ask / sessions (Apple Foundation Models by default)
#   err-models.zsh  the merged marv-mlx engine (local MLX models on :11500)
# See CONTRACT.md for the seams.

_ERR_DIR="${0:A:h}"
export _ERR_DIR

# Model-manager state root. Inherited from marv-mlx on purpose so existing
# config, chats and logs keep working; override with ERR_STATE_DIR.
: "${ERR_STATE_DIR:=$HOME/.cache/marv/mlx}"
export ERR_STATE_DIR

# One conversation per shell (tab / window). A uuid, NOT the PID: pids are
# recycled by the kernel, so a fresh tab could silently inherit a dead tab's
# history. Minted once here and inherited by every err call in this shell.
if [[ -z "${_ERR_SESSION_ID:-}" ]]; then
  if command -v uuidgen >/dev/null 2>&1; then
    _ERR_SESSION_ID="$(uuidgen)"
  else
    _ERR_SESSION_ID="$$-${EPOCHSECONDS}-$RANDOM"
  fi
fi
export _ERR_SESSION_ID

# Per-shell scratch files (not /tmp/err_*: a shared path lets a stale stderr or
# a stale suggestion from an earlier command leak into a later explanation).
_ERR_RUN_DIR="${ERR_STATE_DIR}/run"
mkdir -p "$_ERR_RUN_DIR" 2>/dev/null
_ERR_SESSION_FILE="${_ERR_RUN_DIR}/session.$$"
_ERR_TOKENS_FILE="${_ERR_RUN_DIR}/tokens.$$"
_ERR_SUGGEST_FILE="${_ERR_RUN_DIR}/suggest.$$"
_ERR_STDERR_FILE="${_ERR_RUN_DIR}/stderr.$$"
: > "$_ERR_SESSION_FILE"
: > "$_ERR_TOKENS_FILE"
rm -f "$_ERR_SUGGEST_FILE" "$_ERR_STDERR_FILE" 2>/dev/null

# Turn / token facts for RPROMPT. Updated after every err call, so the prompt
# costs no fork (a per-prompt command substitution would).
typeset -g _ERR_TURNS=0
typeset -g _ERR_TOKENS=0
typeset -g _ERR_RPROMPT_OWNED=0

_err_version() { print -r -- "$(<"$_ERR_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')" }

_err_update_rprompt() {
  # Never clobber a prompt the user already set up; only own an empty RPROMPT.
  if (( ! _ERR_RPROMPT_OWNED )) && [[ -n "${RPROMPT:-}" ]]; then
    return
  fi
  _ERR_RPROMPT_OWNED=1
  if (( _ERR_TURNS > 0 )); then
    local tok="$_ERR_TOKENS"
    (( tok >= 1000 )) && tok="$(( tok / 1000 )).$(( (tok % 1000) / 100 ))k"
    RPROMPT="%F{240}${_ERR_TURNS}t ${tok}%f"
  else
    RPROMPT=""
  fi
}

_err_help() {
  cat <<'USAGE'

err v0.601.0 // in-terminal LLM & local MLX model runner

  err                        correct/explain the last command
  err <question>             ask a command-related or any other question
  err new                    start a fresh session (old one stays resumable)
  err clear | -c             clear the current session, keep the id
  err resume                 resume a previous session
  err delete                 delete all sessions
  err status                 show what is running
  err chat <model>           start a model and open the built-in interactive chat
  err switch <model>         switch to another model
  err default <model>        set model as default
  err run <model>            start a model on port 11500
  err stop <model>           stop a running model (default: all)
  err tui                    interactive TUI (browse / run / download)
  err list                   list installed models err can serve
  err curated                show the full curated model catalog
  err download <model>       download model(s) from the HuggingFace Hub
  err remove <model>         delete model(s) from the disk
  err settings               basic and advanced model settings
  err info <model>           show details for a model (size, family, thinking)
  err cache                  show on-disk footprint (APC, logs, hub, tool env)
  err clean                  delete regenerable caches (never model weights)
  err uninstall              remove err from your system
  err endpoint               print the base URL / model of the running server
  err version | -v           show the current version
  err help | -h              show this help

The first word decides the path: the model verbs above always win, so a
question that starts with one of them needs quoting.  err never runs a
model-suggested command — it drops it into your prompt buffer for you to edit.

USAGE
}

# ── engine bridge ─────────────────────────────────────────────────────

# Verbs served by the ported marv-mlx engine.
_err_engine_verbs=(chat switch default run stop status tui list ls curated
  download remove settings info cache clean uninstall endpoint)

_err_engine() {
  if [[ ! -f "$_ERR_DIR/err-models.zsh" ]]; then
    print -u2 "err: engine missing ($_ERR_DIR/err-models.zsh) — re-run install.sh"
    return 1
  fi
  zsh "$_ERR_DIR/err-models.zsh" "$@"
}

# ── err.py bridge ─────────────────────────────────────────────────────

_err_py() {
  local py
  if command -v python3 >/dev/null 2>&1; then
    py=python3
  elif command -v /usr/bin/python3 >/dev/null 2>&1; then
    py=/usr/bin/python3
  else
    print -u2 "err: python3 not found"
    return 1
  fi
  rm -f "$_ERR_SUGGEST_FILE" 2>/dev/null
  _ERR_SESSION_ID="$_ERR_SESSION_ID" \
  _ERR_SESSION_ID_FILE="$_ERR_SESSION_FILE" \
  _ERR_TOKENS_FILE="$_ERR_TOKENS_FILE" \
  _ERR_SUGGEST_FILE="$_ERR_SUGGEST_FILE" \
  _ERR_STDERR_FILE="$_ERR_STDERR_FILE" \
  _ERR_STATE_DIR="$ERR_STATE_DIR" \
    "$py" "$_ERR_DIR/err.py" "$@"
  local rc=$?

  # A session verb may have changed which conversation this shell is in.
  local newid
  newid="$(<"$_ERR_SESSION_FILE" 2>/dev/null | head -1 | tr -d '[:space:]')"
  [[ -n "$newid" && "$newid" != "$_ERR_SESSION_ID" ]] && _ERR_SESSION_ID="$newid"

  # Token total for the prompt.
  local tok
  tok="$(<"$_ERR_TOKENS_FILE" 2>/dev/null | head -1 | tr -dc '0-9')"
  [[ -n "$tok" ]] && _ERR_TOKENS="$tok"

  _err_take_suggestion
  return $rc
}

# The model's recommended command goes to the prompt buffer, never to the
# shell. print -z is the human-confirmed version of mang.sh's "Run it? [Y/n]".
_err_take_suggestion() {
  [[ -s "$_ERR_SUGGEST_FILE" ]] || return 0
  local cmd
  cmd="$(head -1 "$_ERR_SUGGEST_FILE" 2>/dev/null)"
  rm -f "$_ERR_SUGGEST_FILE" 2>/dev/null
  [[ -z "$cmd" ]] && return 0
  (( ${#cmd} > 400 )) && return 0
  # print -z needs an interactive ZLE-capable shell.
  [[ -o interactive ]] && print -z -- "$cmd"
  return 0
}

# ── last-command tracking (preexec / precmd) ──────────────────────────

_err_last_cmd=""
_err_last_exit=0
_err_skip_exit=0     # set while err itself runs, so its $? can't clobber ours
_err_consumed=0      # set once explained, so a second `err` doesn't repeat it

# Is this command line one of ours? `err` is aliased to `noglob err`, so the
# line preexec sees carries that prefix — matching only "err" would let an err
# call overwrite the last real command with itself.
_err_is_ours() {
  local c="$1"
  c="${c#noglob }"
  [[ "$c" == (err|errc|err\ *|errc\ *) ]]
}

_err_preexec() {
  # $1 is empty when zsh runs the hook outside an interactive command line
  # (scripts, some plugin managers) — never let that wipe the real record.
  [[ -z "${1:-}" ]] && return
  _err_is_ours "$1" && return
  _err_last_cmd="$1"
  _err_consumed=0
}

_err_precmd() {
  local ret=$?
  if (( _err_skip_exit )); then
    _err_skip_exit=0
    return
  fi
  _err_last_exit=$ret
}

if [[ -n "${ZSH_VERSION:-}" ]]; then
  # `typeset -ga` first: under `setopt nounset` (or a caller's `set -u`) an
  # unset hook array would abort the source and leave err undefined.
  typeset -ga preexec_functions precmd_functions
  # Guard against duplicate hooks when the launcher is re-sourced.
  (( ${preexec_functions[(I)_err_preexec]} )) || preexec_functions+=(_err_preexec)
  if (( ! ${precmd_functions[(I)_err_precmd]} )); then
    precmd_functions=(_err_precmd ${precmd_functions[@]})
  fi
elif [[ -n "${BASH_VERSION:-}" ]]; then
  trap 'if [[ "$BASH_COMMAND" != "err" ]]; then _err_last_cmd="$BASH_COMMAND"; _err_consumed=0; fi' DEBUG
  PROMPT_COMMAND="_err_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi

# ── the command ───────────────────────────────────────────────────────

# The alias at the bottom of this file turns `err` into `noglob err`. Without
# dropping it first, re-sourcing (`source ~/.zshrc`, the `reload` alias) parses
# the next line as `noglob err() {` and dies with "defining function based on
# alias". Aliases are expanded at parse time, so this must run before the
# definition below.
unalias err 2>/dev/null || true

err() {
  local last_cmd="$_err_last_cmd"
  local last_exit="$_err_last_exit"
  _err_skip_exit=1

  local verb="${1:-}"

  # ---- model manager verbs (win over free text) ----
  local v
  for v in "${_err_engine_verbs[@]}"; do
    if [[ "$verb" == "$v" ]]; then
      _err_engine "$@"
      return $?
    fi
  done
  case "$verb" in
    version|-v|--version) _err_version; return 0 ;;
    help|-h|--help)       _err_help;    return 0 ;;
  esac

  # ---- session verbs ----
  case "$verb" in
    new|clear|-c|resume|delete)
      _err_py "$@"
      local rc=$?
      case "$verb" in
        new)  _ERR_TURNS=0; _ERR_TOKENS=0 ;;
        clear|-c) _ERR_TURNS=0 ;;
        resume) _ERR_TURNS=1 ;;   # resumed sessions start non-empty
      esac
      _err_update_rprompt
      return $rc
      ;;
  esac

  # ---- explain the last command ----
  if (( $# == 0 )); then
    if [[ -z "$last_cmd" && $_err_consumed -eq 0 ]]; then
      # Fresh session: fall back to history. `builtin fc` because fc may be
      # aliased, and skip our own invocations.
      local h=1
      while (( h <= 10 )); do
        last_cmd="$(builtin fc -ln -$((h)) 2>/dev/null | head -1)"
        [[ -z "$last_cmd" ]] && break
        last_cmd="${last_cmd#"${last_cmd%%[^[:space:]]*}"}"
        last_cmd="${last_cmd%"${last_cmd##*[^[:space:]]}"}"
        case "$last_cmd" in
          *)
            if _err_is_ours "$last_cmd"; then (( h++ )); else break; fi
            ;;
        esac
      done
      last_exit=-1
    fi

    if [[ -z "$last_cmd" ]]; then
      print "🤔 No command to explain." >&2
      return 1
    fi

    _err_last_cmd=""
    _err_consumed=1

    _ERR_LAST_CMD="$last_cmd"
    _ERR_LAST_EXIT="$last_exit"
    export _ERR_LAST_CMD _ERR_LAST_EXIT
    _err_py
    local rc=$?
    (( rc == 0 )) && { (( _ERR_TURNS++ )); _err_update_rprompt; }
    return $rc
  fi

  # ---- ask a question ----
  _ERR_LAST_CMD="$last_cmd"
  _ERR_LAST_EXIT="$last_exit"
  export _ERR_LAST_CMD _ERR_LAST_EXIT
  _err_py --ask "$@"
  local rc=$?
  (( rc == 0 )) && { (( _ERR_TURNS++ )); _err_update_rprompt; }
  return $rc
}

# Run a command, capture its stderr, then explain it. Deliberately NOT
# noglob-aliased: errc runs real commands, so its globs must expand.
errc() {
  "$@" 2> >(tee "$_ERR_STDERR_FILE" >&2)
  local rc=$?
  _err_last_exit=$rc
  _err_last_cmd="$*"
  _err_skip_exit=1
  err
  _err_skip_exit=1
  return $rc
}

# Unquoted `?` (and `*`, `[`) in a question is a zsh "no matches found" error,
# and glob expansion happens before any function runs. noglob is per-command-
# line, so this only affects `err`. Syntax characters — ' " ( ) ; | & < > ! —
# still need quoting: they are parsed before noglob can help.
alias err='noglob err'
