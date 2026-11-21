#!/usr/bin/env zsh
# Dispatch tests for err-launcher.zsh — no fm, no models, no network.
# Stubs both engines and asserts which one each invocation reaches.
# Usage: zsh tests/test_dispatch.zsh
emulate -L zsh
set -u

_ERR_DIR="${0:A:h:h}"
# The menu hands its pick back through $ERR_STATE_DIR/run — keep it out of the
# real state dir.
export ERR_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/err-dispatch.XXXXXX")
typeset -g _CALLS=()
typeset -g _FAILS=0

_check() { # $1 expected, $2 actual, $3 label
  if [[ "$1" == "$2" ]]; then
    print "  ok   $3"
  else
    print "  FAIL $3"
    print "       expected: $1"
    print "       actual:   $2"
    (( _FAILS++ ))
  fi
}

source "$_ERR_DIR/err-launcher.zsh"

# Stub the two engines and the local verbs so nothing escapes the test. Append
# (not replace): `err stop` reaches both the engine and the session reset.
_err_engine() { _CALLS+=( "engine:$*" ) }
_err_py()     { _CALLS+=( "py:$*" ) }
_err_version() { _CALLS=( "version" ) }
# Keep the real menu dispatcher: the protocol checks below need it.
_REAL_HELP_INTERACTIVE=$(typeset -f _err_help_interactive)
_err_help_interactive() { _CALLS=( "helpmenu" ) }
_err_take_suggestion() { : }
_err_last_cmd="lsof -ti:3000"
_err_last_exit=1

print "model verbs -> engine"
for v in "${_err_engine_verbs[@]}"; do
  _CALLS=()
  err $v >/dev/null 2>&1
  _check "engine:$v" "${_CALLS[1]:-}" "err $v"
done

print "stop also resets the conversation"
_CALLS=(); err stop >/dev/null 2>&1
_check "engine:stop py:--reset-session" "${(j: :)_CALLS}" "err stop ends the session"

print "session verbs -> err.py"
for v in new; do
  _CALLS=()
  err $v >/dev/null 2>&1
  _check "py:$v" "${_CALLS[1]:-}" "err $v"
done
_CALLS=(); err resume 2 >/dev/null 2>&1
_check "py:resume 2" "${_CALLS[1]:-}" "err resume 2"

print "local verbs"
_CALLS=(); err version >/dev/null 2>&1
_check "version" "${_CALLS[1]:-}" "err version"
_CALLS=(); err -v >/dev/null 2>&1
_check "version" "${_CALLS[1]:-}" "err -v"
_CALLS=(); err -h >/dev/null 2>&1
_check "helpmenu" "${_CALLS[1]:-}" "err -h opens the menu"
_CALLS=(); err help >/dev/null 2>&1
_check "py:--ask help" "${_CALLS[1]:-}" "err help is a prompt, not a command"

print "free text -> ask"
_CALLS=()
err how do I see open ports >/dev/null 2>&1
_check "py:--ask how do I see open ports" "${_CALLS[1]:-}" "err <question>"

print "bare err -> menu"
_CALLS=()
err >/dev/null 2>&1
_check "helpmenu" "${_CALLS[1]:-}" "err (no args opens the menu)"

print "explain word"
for w in wtf; do
  _CALLS=()
  _err_last_cmd="lsof -ti:3000"; _err_consumed=0   # explain consumes the record
  err $w >/dev/null 2>&1
  _check "py:" "${_CALLS[1]:-}" "err $w explains the last command"
done
_CALLS=()
err wtf did that fail >/dev/null 2>&1
_check "py:--ask wtf did that fail" "${_CALLS[1]:-}" "err wtf ... asks a question"

print "the menu re-dispatches its row through err"
eval "$_REAL_HELP_INTERACTIVE"
_CALLS=()
_err_engine() {
  if [[ "$1" == helpmenu ]]; then print -r -- "run"$'\t'"mock-org/Picked" > "$2"
  else _CALLS=( "engine:$*" ); fi
}
_err_help_interactive >/dev/null 2>&1
_check "engine:run mock-org/Picked" "${_CALLS[1]:-}" "a picked model runs by name"
_CALLS=()
_err_engine() {
  if [[ "$1" == helpmenu ]]; then print -r -- "ask"$'\t'"what is a glob" > "$2"
  else _CALLS=( "engine:$*" ); fi
}
_err_help_interactive >/dev/null 2>&1
_check "py:--ask what is a glob" "${_CALLS[1]:-}" "a typed question goes to err.py"
_CALLS=()
_err_engine() { return 1 }
_err_help_interactive >/dev/null 2>&1
_check "0" "$?" "esc in the menu is a clean exit"

print "unquoted ? survives (noglob alias)"
_CALLS=()
eval 'err what ports are in use?' >/dev/null 2>&1
_check "py:--ask what ports are in use?" "${_CALLS[1]:-}" "err ... ports?"

print "preexec guard (_err_is_ours)"
for c in err "err run" "noglob err" "noglob err how do I" "err wtf"; do
  _check yes "$(_err_is_ours "$c" && echo yes || echo no)" "ours: $c"
done
for c in "ls -la" "git status" "echo err" "echo " "noglob ls"; do
  _check no "$(_err_is_ours "$c" && echo yes || echo no)" "not ours: $c"
done

print "suggestion channel never executes"
_sug_tmp=$(mktemp -d)
_sug_file="$_sug_tmp/suggest"
_sug_canary="$_sug_tmp/PWNED"
print -r -- "touch $_sug_canary" > "$_sug_file"
_ERR_SUGGEST_FILE="$_sug_file"
# history mode (default): the line must be appended to history, not run
_err_take_suggestion
_check "no" "$([[ -e "$_sug_canary" ]] && echo yes || echo no)" "a suggested 'touch' was not executed"
_check "no" "$([[ -e "$_sug_canary" ]] && echo yes || echo no)" "and still was not executed after the second pass"
_check "yes" "$([[ -s "$_sug_file" ]] && echo yes || echo no)" "history mode consumes the suggestion file"
# off mode: nothing is consumed at all
print -r -- "touch $_sug_canary" > "$_sug_file"
_saved_suggest="${ERR_SUGGEST:-}"; ERR_SUGGEST=off
_err_take_suggestion
ERR_SUGGEST="$_saved_suggest"
_check "yes" "$([[ -s "$_sug_file" ]] && echo yes || echo no)" "suggest=off leaves the file alone"
remove=(); rm -rf "$_sug_tmp"

print "RPROMPT is not clobbered"
_saved_rp="mine"; RPROMPT="$_saved_rp"; _ERR_RPROMPT_OWNED=0
_ERR_TURNS=2; _ERR_TOKENS=10
_err_update_rprompt
_check "$_saved_rp" "$RPROMPT" "a user RPROMPT survives err"
RPROMPT=""; _ERR_RPROMPT_OWNED=0; _err_update_rprompt
contains_rp="${RPROMPT}"
_check "yes" "$([[ -n "$contains_rp" ]] && echo yes || echo no)" "an empty RPROMPT gets the turn counter"
RPROMPT=""

print "sensible defaults from err.conf"
_check "history" "$(_err_suggest_mode)" "suggest = history (↑ recalls, no auto-fill)"
_saved_dir="$_ERR_DIR"
_tmpdir=$(mktemp -d)
for _v in off ask history; do
  print "suggest = $_v" > "$_tmpdir/err.conf"
  _ERR_DIR="$_tmpdir"
  _check "$_v" "$(_err_suggest_mode)" "suggest = $_v parsed"
done
_ERR_DIR="$_saved_dir"; rm -rf "$_tmpdir"

print 're-sourcing (the `reload` alias sources ~/.zshrc again)'
_reload_out=$(zsh -f -c "source '$_ERR_DIR/err-launcher.zsh'; source '$_ERR_DIR/err-launcher.zsh'; print ok" 2>&1)
_check "ok" "$_reload_out" "second source parses and runs"
_reload_hooks=$(zsh -f -c "source '$_ERR_DIR/err-launcher.zsh'; source '$_ERR_DIR/err-launcher.zsh'; print \${#preexec_functions} \${#precmd_functions}" 2>&1)
_check "1 1" "$_reload_hooks" "hooks are not duplicated"

print "RPROMPT ownership"
# After a re-source the ownership flag is back at 0 while the previous prompts
# still shows err's counts. Recognize that exact shape and take it back.
RPROMPT='%F{240}2t 207%f'; _ERR_RPROMPT_OWNED=0; _ERR_TURNS=0; _ERR_TOKENS=0
_err_update_rprompt
_check "" "$RPROMPT" "err reclaims its own RPROMPT after a re-source"
RPROMPT='%F{1}mine%f'; _ERR_RPROMPT_OWNED=0
_err_update_rprompt
_check '%F{1}mine%f' "$RPROMPT" "a user RPROMPT is left alone"
RPROMPT=''

print ""
if (( _FAILS )); then
  print "FAILED: $_FAILS"
  exit 1
fi
print "all dispatch tests passed"
