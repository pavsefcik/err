#!/usr/bin/env zsh
# err 0.5 — thin shell shim (hooks + Python handoff)
# Configuration lives in err.conf next to this file.

_err_last_cmd=""
_err_last_exit=0

_err_preexec() {
  [[ "$1" == "err" || "$1" == err\ * || "$1" == "errc" || "$1" == errc\ * ]] && return
  _err_last_cmd="$1"
}

_err_precmd() {
  _err_last_exit=$?
}

if [[ -n "$ZSH_VERSION" ]]; then
  preexec_functions+=(_err_preexec)
  precmd_functions=(_err_precmd "${precmd_functions[@]}")
elif [[ -n "$BASH_VERSION" ]]; then
  trap '[[ "$BASH_COMMAND" != "err" ]] && _err_last_cmd="$BASH_COMMAND"' DEBUG
  PROMPT_COMMAND="_err_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi

_ERR_PROJECT="${0:A:h}"

err() {
  local last_cmd="$_err_last_cmd"
  local last_exit="$_err_last_exit"
  if [[ -z "$last_cmd" ]]; then
    # Fall back to the last real command from history (err/errc lines are skipped).
    # Uses `builtin fc` because the user may alias `fc` to something else.
    local h=1
    while (( h <= 10 )); do
      last_cmd="$(builtin fc -ln -$((h)) 2>/dev/null | head -1)"
      [[ -z "$last_cmd" ]] && break
      last_cmd="${last_cmd#"${last_cmd%%[^[:space:]]*}"}"   # trim leading ws
      last_cmd="${last_cmd%"${last_cmd##*[^[:space:]]}"}"   # trim trailing ws
      case "$last_cmd" in
        err|err\ *|errc|errc\ *) (( h++ )) ;;
        *) break ;;
      esac
    done
    last_exit=-1
  fi
  _ERR_LAST_CMD="$last_cmd" _ERR_LAST_EXIT="$last_exit" \
    python3 "$_ERR_PROJECT/err.py" "$@"
}

# Run a command with stderr capture, then auto-explain
errc() {
  "$@" 2> >(tee /tmp/err_stderr >&2)
  _err_last_exit=$?
  _err_last_cmd="$*"
  err
}
