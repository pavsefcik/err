#!/usr/bin/env zsh
# err 0.602 — shell shim: hooks, dispatch, per-shell facts.
# Add to ~/.zshrc:  source "/path/to/err-launcher.zsh"
#
# Two engines behind one command:
#   err.py          explain / ask / sessions (Apple Foundation Models by default)
#   err-models.zsh  the merged marv-mlx engine (local MLX models on :11500)
# See CONTRACT.md for the seams.

_ERR_DIR="${0:A:h}"
export _ERR_DIR

# err's own state root. Deliberately NOT ~/.cache/marv (that belongs to the
# marv harness and its embedded launches); override with ERR_STATE_DIR.
: "${ERR_STATE_DIR:=$HOME/.cache/err}"
ERR_STATE_DIR="${ERR_STATE_DIR:A}"      # absolute, ~ expanded, no trailing /
export ERR_STATE_DIR

# Keep the random boundary token in the shell, but never export it to commands
# being captured (otherwise a command could forge its own end marker).
if [[ "${ERR_PTY_PROXY_ACTIVE:-0}" == 1 ]]; then
  typeset -g ERR_PTY_TOKEN="${ERR_PTY_TOKEN:-}"
  typeset +x ERR_PTY_TOKEN
fi

# PTY capture startup is handled by ~/.zshrc, never while sourcing this file.

# One-time move of err's state out of the old shared marv-mlx root. Only err's
# own files come across: apc/, logs/ and venvs/ are regenerable and stay behind
# with marv. Runs once, guarded by the new directory not existing yet.
if [[ ! -e "$ERR_STATE_DIR" && -d "$HOME/.cache/marv/mlx" ]]; then
  (
    mkdir -p "$ERR_STATE_DIR" 2>/dev/null
    for _p in sessions last-model; do
      [[ -e "$HOME/.cache/marv/mlx/$_p" ]] && \
        cp -R "$HOME/.cache/marv/mlx/$_p" "$ERR_STATE_DIR/$_p" 2>/dev/null
    done
    # The catalog is err-curator.md now; marv's copy still carries the old name,
    # so it lands under the new one or the first sync would ignore it.
    [[ -e "$HOME/.cache/marv/mlx/curated-llms.md" ]] && \
      cp -R "$HOME/.cache/marv/mlx/curated-llms.md" "$ERR_STATE_DIR/err-curator.md" 2>/dev/null
  )
fi

# One conversation per shell (tab / window). A uuid, NOT the PID: pids are
# recycled by the kernel, so a fresh tab could silently inherit a dead tab's
# history. Minted once here and inherited by every err call in this shell.
if [[ -z "${_ERR_SESSION_ID:-}" ]]; then
  if command -v uuidgen >/dev/null 2>&1; then
    _ERR_SESSION_ID="$(uuidgen)"
  elif command -v python3 >/dev/null 2>&1; then
    # err.py only accepts a real uuid; a made-up id would make it mint a new
    # one per call and lose the conversation.
    _ERR_SESSION_ID="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)"
  fi
  : "${_ERR_SESSION_ID:=}"
fi
export _ERR_SESSION_ID

# Per-shell scratch files (not /tmp/err_*: a shared path lets a stale stderr or
# a stale suggestion from an earlier command leak into a later explanation).
_ERR_RUN_DIR="${ERR_STATE_DIR}/run"
mkdir -p "$_ERR_RUN_DIR" 2>/dev/null
_ERR_SESSION_FILE="${_ERR_RUN_DIR}/session.$$"
_ERR_TOKENS_FILE="${_ERR_RUN_DIR}/tokens.$$"
_ERR_TURNS_FILE="${_ERR_RUN_DIR}/turns.$$"
_ERR_SUGGEST_FILE="${_ERR_RUN_DIR}/suggest.$$"
_ERR_STDERR_FILE="${_ERR_RUN_DIR}/stderr.$$"
_ERR_STDOUT_FILE="${ERR_PTY_CAPTURE_FILE:-${_ERR_RUN_DIR}/stdout.$$}"
# The destination is needed by err.py only; captured programs must not inherit it.
typeset +x ERR_PTY_CAPTURE_FILE
: > "$_ERR_SESSION_FILE"
: > "$_ERR_TOKENS_FILE"
: > "$_ERR_TURNS_FILE"
rm -f "$_ERR_SUGGEST_FILE" "$_ERR_STDERR_FILE" "$_ERR_STDOUT_FILE" 2>/dev/null

# Scratch files are named after the owning shell's pid. Reap the ones whose
# shell is gone — nothing else ever deletes them, and a laptop that opens a few
# terminals a day would otherwise accumulate thousands.
_err_reap_scratch() {
  local f pid
  for f in "$_ERR_RUN_DIR"/*(N); do
    pid="${f##*.}"
    [[ "$pid" == <-> ]] || continue
    [[ "$pid" == "$$" ]] && continue
    kill -0 "$pid" 2>/dev/null || rm -f "$f" 2>/dev/null
  done
}
_err_reap_scratch

# Remove this shell's own scratch files on exit (zshexit hook, not a custom
# `zshexit` function, so a user override is never clobbered).
_err_cleanup_scratch() {
  rm -f "$_ERR_SESSION_FILE" "$_ERR_TOKENS_FILE" "$_ERR_TURNS_FILE" "$_ERR_SUGGEST_FILE" "$_ERR_STDERR_FILE" "$_ERR_STDOUT_FILE" 2>/dev/null
}
if [[ -n "${ZSH_VERSION:-}" ]]; then
  autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook zshexit _err_cleanup_scratch
fi

# Turn / token facts for RPROMPT. Updated after every err call, so the prompt
# costs no fork (a per-prompt command substitution would). Preserved across a
# re-source: resetting them to 0 while the prompt still shows the old counts is
# how the counter used to freeze.
typeset -g _ERR_TURNS="${_ERR_TURNS:-0}"
typeset -g _ERR_TOKENS="${_ERR_TOKENS:-0}"
typeset -g _ERR_RPROMPT_OWNED="${_ERR_RPROMPT_OWNED:-0}"

# In the proxy child shell, hooks emit output-boundary markers.
# The legacy `capture = on` tee mode is intentionally disabled.
_err_capture_mode() { [[ "${ERR_PTY_PROXY_ACTIVE:-0}" == 1 ]] }

# When this shell loaded the launcher. Used to spot a stale in-memory `err`
# after the file changed on disk — `switch`/`help` live here, so a stale copy
# silently ignores them until you reload.
# EPOCHSECONDS comes from zsh/datetime and is unset under `zsh -f`, so fall
# back to date(1) rather than 0 (which would flag every shell as stale).
typeset -g _ERR_LOADED_AT="${_ERR_LOADED_AT:-${EPOCHSECONDS:-$(date +%s)}}"
export _ERR_LOADED_AT

_err_version() {
  print -r -- "$(<"$_ERR_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
  local src="$_ERR_DIR/err-launcher.zsh" mtime
  mtime=$(/usr/bin/stat -f %m "$src" 2>/dev/null)
  if [[ -n "$mtime" ]] && (( mtime > _ERR_LOADED_AT )); then
    print -u2 "err: warning: err-launcher.zsh changed on disk after this shell loaded it"
    print -u2 "     this shell runs stale code for dispatch/help — run: reload"
  fi
}

_err_update_rprompt() {
  # Never clobber a prompt the user set up; only own an empty RPROMPT. The
  # exception is err's own previous value: after a re-source both flags are
  # back at 0 while the screen still shows `2t 207`, so recognize that exact
  # shape and take the prompt back (otherwise it freezes forever).
  if (( ! _ERR_RPROMPT_OWNED )) && [[ -n "${RPROMPT:-}" ]]; then
    [[ "$RPROMPT" == '%F{240}'<->t' '*%f ]] || return
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

# Bare `err` / `err -h` / `err help` is the interactive menu. The engine owns
# the rows and the pickers (it already knows the models, the config and the
# running server); it hands back one chosen line and this dispatches it by
# name. Never `eval`: a row can only ever be one of err's own verbs, and the
# menu cannot drift from
# what typing the same command does.
_err_help_interactive() {
  # The pick cannot come back through `$( )`: that makes stdout a pipe, and the
  # engine would print the rows instead of opening the picker. So it writes the
  # chosen line to a per-invocation scratch file and stdout stays the terminal.
  local dir="${ERR_STATE_DIR:-$HOME/.cache/err}/run"
  mkdir -p "$dir" 2>/dev/null
  local out="$dir/helpmenu.$$"
  : >| "$out" 2>/dev/null
  _err_engine helpmenu "$out"
  local rc=$? pick=""
  [[ -r "$out" ]] && pick=$(<"$out")
  rm -f "$out" 2>/dev/null
  (( rc == 0 )) || return 0     # esc, or no menu to show: a clean no-op
  [[ -z "$pick" ]] && return 0  # the rows were printed; that was the answer
  local verb="${pick%%$'\t'*}"
  local rest="${pick#*$'\t'}"
  [[ "$rest" == "$pick" ]] && rest=""
  if [[ "$verb" == ask ]]; then
    err "$rest"
  elif [[ -n "$rest" ]]; then
    err "$verb" "$rest"
  else
    err "$verb"
  fi
}

# ── engine bridge ─────────────────────────────────────────────────────

# Verbs served by the ported marv-mlx engine.
_err_engine_verbs=(
  # model manager (every `case` arm in err-models.zsh that a user can type)
  swap switch run serve stop doctor
  list ls download remove rm config reset info cleanup
  uninstall ensure
)

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
  [[ "${1:-}" == --record ]] || rm -f "$_ERR_SUGGEST_FILE" 2>/dev/null
  _ERR_SESSION_ID="$_ERR_SESSION_ID" \
  _ERR_SESSION_ID_FILE="$_ERR_SESSION_FILE" \
  _ERR_TOKENS_FILE="$_ERR_TOKENS_FILE" \
  _ERR_TURNS_FILE="$_ERR_TURNS_FILE" \
  _ERR_SUGGEST_FILE="$_ERR_SUGGEST_FILE" \
  _ERR_STDERR_FILE="$_ERR_STDERR_FILE" \
  _ERR_STDOUT_FILE="$_ERR_STDOUT_FILE" \
    "$py" "$_ERR_DIR/err.py" "$@"
  local rc=$?

  # A session verb may have changed which conversation this shell is in.
  local newid
  newid="$(<"$_ERR_SESSION_FILE" 2>/dev/null | head -1 | tr -d '[:space:]')"
  [[ -n "$newid" && "$newid" != "$_ERR_SESSION_ID" ]] && _ERR_SESSION_ID="$newid"

  # Token/turn total for the prompt: err.py publishes the current session's
  # counters, so `new` resets them and `resume` adopts the resumed session's.
  local tok
  tok="$(<"$_ERR_TOKENS_FILE" 2>/dev/null | head -1 | tr -dc '0-9')"
  [[ -n "$tok" ]] && _ERR_TOKENS="$tok"
  local turns
  turns="$(<"$_ERR_TURNS_FILE" 2>/dev/null | head -1 | tr -dc '0-9')"
  [[ -n "$turns" ]] && _ERR_TURNS="$turns"

  _err_take_suggestion
  return $rc
}

# err.conf -> suggest: history | ask | off
#   history (default)  append to shell history — press ↑ to recall, edit, run
#   ask                drop straight into the prompt buffer (print -z)
#   off                don't offer the command at all
_err_suggest_mode() {
  # same precedence as err.py: ERR_SUGGEST, then err.conf, then history
  if [[ -n "${ERR_SUGGEST:-}" ]]; then print -r -- "${ERR_SUGGEST:l}"; return; fi
  local v="" conf="${ERR_CONF:-$ERR_STATE_DIR/err.conf}"
  [[ -r "$conf" ]] && v=$(grep -E '^[[:space:]]*suggest[[:space:]]*=' \
    "$conf" 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')
  print -r -- "${v:-history}"
}

# The model's recommended command never reaches the shell on its own. With the
# default it only lands in history, so ↑ is the confirmation step.
_err_take_suggestion() {
  [[ -s "$_ERR_SUGGEST_FILE" ]] || return 0
  local cmd mode
  cmd="$(head -1 "$_ERR_SUGGEST_FILE" 2>/dev/null)"
  rm -f "$_ERR_SUGGEST_FILE" 2>/dev/null
  [[ -z "$cmd" ]] && return 0
  (( ${#cmd} > 400 )) && return 0
  [[ -o interactive ]] || return 0
  mode="$(_err_suggest_mode)"
  case "$mode" in
    off) return 0 ;;
    ask|buffer) print -z -- "$cmd" ;;
    *)
      # No duplicate if that command is already the newest history entry.
      local prev
      prev="$(builtin fc -ln -1 2>/dev/null | sed 's/^[[:space:]]*//')"
      [[ "$prev" == "$cmd" ]] || print -s "$cmd"
      ;;
  esac
  return 0
}

# ── last-command tracking (preexec / precmd) ──────────────────────────

_err_last_cmd=""
_err_last_exit=0
_err_skip_exit=0     # set while err itself runs, so its $? can't clobber ours
_err_consumed=0      # set once explained, so a second `err` doesn't repeat it
_err_fresh=0         # 1 while the last command has not been talked about yet

# Is this command line one of ours? `err` is aliased to `noglob err`, so the
# line preexec sees carries that prefix — matching only "err" would let an err
# call overwrite the last real command with itself.
_err_is_ours() {
  local c="$1"
  c="${c#noglob }"
  [[ "$c" == (err|err\ *) ]]
}

typeset -g _ERR_PTY_COMMAND_ACTIVE=0
_err_preexec() {
  _ERR_PTY_COMMAND_ACTIVE=0
  # $1 is empty when zsh runs the hook outside an interactive command line
  # (scripts, some plugin managers) — never let that wipe the real record.
  [[ -z "${1:-}" ]] && return
  _err_is_ours "$1" && return
  local c="$1"
  # A pipeline ending in `| err …` is err reading some other command's output.
  # err is the LAST stage, so _err_is_ours misses it: check the tail here and
  # record nothing, or the whole pipeline would become "the command".
  if [[ "$c" == *"|"* ]]; then
    local tail="${c##*|}"
    tail="${tail#"${tail%%[^[:space:]]*}"}"
    _err_is_ours "$tail" && return
  fi
  _err_last_cmd="$c"
  _err_consumed=0
  _err_fresh=1
  # Clear prior output; the PTY relay repopulates it between this command's markers.
  : >| "$_ERR_STDOUT_FILE" 2>/dev/null
  : >| "$_ERR_STDERR_FILE" 2>/dev/null
  if _err_capture_mode; then
    _ERR_PTY_COMMAND_ACTIVE=1
    print -rn -- $'\e]18188736;'"${ERR_PTY_TOKEN}"$';S\a'
  fi
}

_err_precmd() {
  local ret=$?
  if _err_capture_mode && (( _ERR_PTY_COMMAND_ACTIVE )); then
    print -rn -- $'\e]18188736;'"${ERR_PTY_TOKEN}"$';E\a'
    _ERR_PTY_COMMAND_ACTIVE=0
  fi
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
    # End capture after other precmd integrations, immediately before zsh draws
    # the prompt, so their prompt decorations are not mistaken for command output.
    precmd_functions+=(_err_precmd)
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
  local verb="${1:-}"

  # Read-only inspection does not consume the one-turn command context.
  if [[ "$verb" == record && $# == 1 ]]; then
    _ERR_LAST_CMD="$last_cmd"
    _ERR_LAST_EXIT="$last_exit"
    export _ERR_LAST_CMD _ERR_LAST_EXIT
    _err_skip_exit=1
    _err_py --record
    return $?
  fi

  # Snapshot before anything can consume it: the ask path uses it as context,
  # and *any* ordinary err call means the command is no longer "the one just run".
  local fresh=$_err_fresh
  _err_fresh=0
  _err_skip_exit=1

  # ---- no arguments: the interactive menu ----
  if (( $# == 0 )); then
    _err_help_interactive
    return $?
  fi

  # ---- model manager verbs (win over free text) ----
  local v
  for v in "${_err_engine_verbs[@]}"; do
    if [[ "$verb" == "$v" ]]; then
      _err_engine "$@"
      local rc=$?
      # `err stop` ends the conversation too: the model is gone, so the next
      # start gets a fresh session (and a cleared turn/token counter).
      if [[ "$v" == stop && $rc -eq 0 ]]; then
        _err_py --reset-session >/dev/null 2>&1
        _err_update_rprompt
      fi
      return $rc
    fi
  done
  case "$verb" in
    version|-v|-V|--version) _err_version; return 0 ;;
    help|-h|--help)       _err_help_interactive; return $? ;;
  esac

  # ---- session verbs ----
  case "$verb" in
    new|resume)
      _err_py "$@"
      local rc=$?
      _err_update_rprompt
      return $rc
      ;;
  esac

  # ---- explain the last command: `err wtf` ----
  # Only when the word stands alone; `err wtf did that fail` stays a question.
  case "$verb" in
    wtf)
      if (( $# == 1 )); then
        _err_explain "$last_cmd" "$last_exit"
        local rc=$?
        (( rc == 0 || ! fresh )) || _err_fresh=1
        return $rc
      fi
      ;;
  esac

  # ---- ask a question ----
  _ERR_LAST_CMD="$last_cmd"
  _ERR_LAST_EXIT="$last_exit"
  _ERR_LAST_FRESH="$fresh"
  export _ERR_LAST_CMD _ERR_LAST_EXIT _ERR_LAST_FRESH
  _err_py --ask "$@"
  local rc=$?
  if (( rc != 0 && fresh )); then _err_fresh=1; fi
  (( rc == 0 )) && _err_update_rprompt
  return $rc
}

# Explain the last command (`err wtf`).
_err_explain() {
  local last_cmd="$1"
  local last_exit="$2"
  _err_skip_exit=1

  if [[ -z "$last_cmd" && $_err_consumed -eq 0 ]]; then
    # Fresh session: fall back to history. `builtin fc` because fc may be
    # aliased, and skip our own invocations.
    local h=1
    while (( h <= 10 )); do
      last_cmd="$(builtin fc -ln -$((h)) 2>/dev/null | head -1)"
      [[ -z "$last_cmd" ]] && break
      last_cmd="${last_cmd#"${last_cmd%%[^[:space:]]*}"}"
      last_cmd="${last_cmd%"${last_cmd##*[^[:space:]]}"}"
      if _err_is_ours "$last_cmd"; then (( h++ )); else break; fi
    done
    last_exit=-1
  fi

  if [[ -z "$last_cmd" ]]; then
    print "err: no command to explain." >&2
    return 1
  fi

  # Consume the record so a second `err wtf` doesn't repeat it.
  _err_last_cmd=""
  _err_consumed=1
  _err_fresh=0

  _ERR_LAST_CMD="$last_cmd"
  _ERR_LAST_EXIT="$last_exit"
  _ERR_LAST_FRESH=0
  export _ERR_LAST_CMD _ERR_LAST_EXIT _ERR_LAST_FRESH
  _err_py
  local rc=$?
  if (( rc != 0 )); then
    _err_last_cmd="$last_cmd"
    _err_last_exit="$last_exit"
    _err_consumed=0
  fi
  (( rc == 0 )) && _err_update_rprompt
  return $rc
}

# Unquoted `?` (and `*`, `[`) in a question is a zsh "no matches found" error,
# and glob expansion happens before any function runs. noglob is per-command-
# line, so this only affects `err`. Syntax characters — ' " ( ) ; | & < > ! —
# still need quoting: they are parsed before noglob can help.
alias err='noglob err'
