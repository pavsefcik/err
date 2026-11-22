# Source this near the top of an interactive zsh startup file to enable
# `capture = pty`. If ERR_STATE_DIR/ERR_CONF is assigned in .zshrc, put this
# after that assignment (or set ERR_CAPTURE=pty in the environment). Kept
# separate from err-launcher.zsh so sourcing the launcher never replaces its caller.

if [[ "${ERR_PTY_PROXY_ACTIVE:-0}" == 1 ]]; then
  # Commands must not inherit the random OSC boundary token.
  typeset +x ERR_PTY_TOKEN
fi

if [[ -o interactive && -t 0 && -t 1 \
      && -z "${ZSH_EXECUTION_STRING:-}" \
      && "${${ZSH_ARGZERO:t}#-}" == "$ZSH_NAME" \
      && "${ERR_PTY_PROXY_ACTIVE:-0}" != 1 ]]; then
  _err_pty_setting="${ERR_CAPTURE:-}"
  if [[ -z "$_err_pty_setting" ]]; then
    _err_pty_conf="${ERR_CONF:-${ERR_STATE_DIR:-$HOME/.cache/err}/err.conf}"
    if [[ -r "$_err_pty_conf" ]]; then
      typeset _err_pty_key _err_pty_value
      while IFS='=' read -r _err_pty_key _err_pty_value; do
        _err_pty_key="${_err_pty_key//[[:space:]]/}"
        if [[ "$_err_pty_key" == capture ]]; then
          _err_pty_setting="${_err_pty_value//[[:space:]]/}"
          break
        fi
      done < "$_err_pty_conf"
    fi
  fi

  if [[ "${_err_pty_setting:l}" == pty ]]; then
    _err_pty_repo="${0:A:h:h}"
    _err_pty_state="${ERR_STATE_DIR:-$HOME/.cache/err}"
    _err_pty_path="${_err_pty_state:A}/run/pty-output.${RANDOM}.$$"
    _err_pty_shell=$(command -v zsh 2>/dev/null)
    mkdir -p "${_err_pty_path:h}" 2>/dev/null
    chmod 700 "${_err_pty_path:h}" 2>/dev/null
    if [[ -n "$_err_pty_shell" && -o login ]]; then
      exec python3 "$_err_pty_repo/lib/err-pty-proxy.py" \
        --capture-file "$_err_pty_path" -- "$_err_pty_shell" -l -i
    elif [[ -n "$_err_pty_shell" ]]; then
      exec python3 "$_err_pty_repo/lib/err-pty-proxy.py" \
        --capture-file "$_err_pty_path" -- "$_err_pty_shell" -i
    fi
  fi
fi
