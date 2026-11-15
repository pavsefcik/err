#!/usr/bin/env zsh
# Dispatch tests for err-launcher.zsh — no fm, no models, no network.
# Stubs both engines and asserts which one each invocation reaches.
# Usage: zsh tests/test_dispatch.zsh
emulate -L zsh
set -u

_ERR_DIR="${0:A:h:h}"
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

# Stub the two engines and the local verbs so nothing escapes the test.
_err_engine() { _CALLS=( "engine:$*" ) }
_err_py()     { _CALLS=( "py:$*" ) }
_err_version() { _CALLS=( "version" ) }
_err_help()    { _CALLS=( "help" ) }
_err_take_suggestion() { : }
_err_last_cmd="lsof -ti:3000"
_err_last_exit=1

print "model verbs -> engine"
for v in "${_err_engine_verbs[@]}"; do
  _CALLS=()
  err $v >/dev/null 2>&1
  _check "engine:$v" "${_CALLS[1]:-}" "err $v"
done

print "session verbs -> err.py"
for v in new clear delete; do
  _CALLS=()
  err $v >/dev/null 2>&1
  _check "py:$v" "${_CALLS[1]:-}" "err $v"
done
_CALLS=(); err -c >/dev/null 2>&1
_check "py:-c" "${_CALLS[1]:-}" "err -c"
_CALLS=(); err resume 2 >/dev/null 2>&1
_check "py:resume 2" "${_CALLS[1]:-}" "err resume 2"

print "local verbs"
_CALLS=(); err version >/dev/null 2>&1
_check "version" "${_CALLS[1]:-}" "err version"
_CALLS=(); err -v >/dev/null 2>&1
_check "version" "${_CALLS[1]:-}" "err -v"
_CALLS=(); err help >/dev/null 2>&1
_check "help" "${_CALLS[1]:-}" "err help"

print "free text -> ask"
_CALLS=()
err how do I see open ports >/dev/null 2>&1
_check "py:--ask how do I see open ports" "${_CALLS[1]:-}" "err <question>"

print "bare err -> help"
_CALLS=()
err >/dev/null 2>&1
_check "help" "${_CALLS[1]:-}" "err (no args shows help)"

print "explain words"
for w in what why wtf; do
  _CALLS=()
  _err_last_cmd="lsof -ti:3000"; _err_consumed=0   # explain consumes the record
  err $w >/dev/null 2>&1
  _check "py:" "${_CALLS[1]:-}" "err $w explains the last command"
done
_CALLS=()
err what is a glob >/dev/null 2>&1
_check "py:--ask what is a glob" "${_CALLS[1]:-}" "err what is a glob asks a question"
_CALLS=()
err why did that fail >/dev/null 2>&1
_check "py:--ask why did that fail" "${_CALLS[1]:-}" "err why did that fail asks a question"

print "errc explains without printing help"
_CALLS=()
errc true >/dev/null 2>&1
_check "py:" "${_CALLS[1]:-}" "errc <cmd> goes to the explainer"

print "unquoted ? survives (noglob alias)"
_CALLS=()
eval 'err what ports are in use?' >/dev/null 2>&1
_check "py:--ask what ports are in use?" "${_CALLS[1]:-}" "err ... ports?"

print "preexec guard (_err_is_ours)"
for c in err "err run" "noglob err" "noglob err how do I" errc "errc ls -la" "noglob errc ls"; do
  _check yes "$(_err_is_ours "$c" && echo yes || echo no)" "ours: $c"
done
for c in "ls -la" "git status" "echo err" "echo errc" "noglob ls"; do
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

print ""
if (( _FAILS )); then
  print "FAILED: $_FAILS"
  exit 1
fi
print "all dispatch tests passed"
