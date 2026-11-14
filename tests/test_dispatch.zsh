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
_err_update_rprompt()  { : }
_err_last_cmd="lsof -ti:3000"
_err_last_exit=1

print "model verbs -> engine"
for v in run switch default stop status tui list curated download remove settings info cache clean uninstall endpoint; do
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

print "bare -> explain"
_CALLS=()
err >/dev/null 2>&1
_check "py:" "${_CALLS[1]:-}" "err (explain, no args)"

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

print ""
if (( _FAILS )); then
  print "FAILED: $_FAILS"
  exit 1
fi
print "all dispatch tests passed"
