#!/usr/bin/env zsh
# End-to-end smoke: the REAL launcher + err.py + engine, against a mock
# OpenAI server, in a throwaway ERR_STATE_DIR / ERR_CONF / ERR_HUB_DIR.
#
# These assert what the USER sees (output, exit code, conf, history), not
# internal calls. Menus are err's own; off a terminal they print their rows and
# abort, which is the same code path a human drives with keys.
#
# Usage: zsh tests/smoke.zsh
emulate -L zsh
setopt pipefail
set -u

REPO="${0:A:h:h}"
typeset -g _FAILS=0 _PASSES=0 _TMP=""

cleanup() { [[ -n "$_TMP" ]] && rm -rf "$_TMP"; [[ -n "${_MOCK_PID:-}" ]] && kill "$_MOCK_PID" 2>/dev/null }
trap cleanup EXIT INT TERM

ok()   { (( _PASSES++ )); print "  ok   $1" }
fail() { (( _FAILS++ ));  print "  FAIL $1"; [[ -n "${2:-}" ]] && print "       ${2[1,300]}" }
contains()     { if print -r -- "$2" | grep -qF -- "$1"; then ok "$3"; else fail "$3" "missing: [$1] in: [${2[1,300]}]"; fi }
not_contains() { if print -r -- "$2" | grep -qF -- "$1"; then fail "$3" "unexpected: [$1] in: [${2[1,300]}]"; else ok "$3"; fi }
check()        { if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3" "expected [$1] actual [$2]"; fi }

# ── isolated environment ────────────────────────────────────────────────
_TMP=$(mktemp -d "${TMPDIR:-/tmp}/err-smoke.XXXXXX")
export ERR_STATE_DIR="$_TMP/state"
export ERR_CONF="$_TMP/err.conf"
export ERR_HUB_DIR="$_TMP/hub"          # keep the real HF cache out of this
export ERR_MLX_MODEL="mock/model"       # "the model lives on that server"
export EDITOR=true                      # `err config` must not really open vi
mkdir -p "$ERR_HUB_DIR" "$ERR_STATE_DIR" "$_TMP/bin"

python3 "$REPO/tests/mock_serve.py" "$_TMP/port" >"$_TMP/mock.log" 2>&1 &
_MOCK_PID=$!
for _i in {1..100}; do [[ -s "$_TMP/port" ]] && break; sleep 0.1; done
if [[ ! -s "$_TMP/port" ]]; then
  print "FATAL: mock server did not start:" >&2
  cat "$_TMP/mock.log" >&2
  exit 1
fi
MOCK_URL="$(<"$_TMP/port")"

# A fake model in the throwaway hub, so read-only verbs have something to show.
FAKE_MODEL="mock-org/Fake-4bit"
mkdir -p "$ERR_HUB_DIR/models--mock-org--Fake-4bit/snapshots/rev"
print -r -- "weights" > "$ERR_HUB_DIR/models--mock-org--Fake-4bit/snapshots/rev/model.safetensors"
print -r -- '{"model_type":"qwen2"}' \
  > "$ERR_HUB_DIR/models--mock-org--Fake-4bit/snapshots/rev/config.json"

# A conf that talks to the mock and never tries to launch anything real.
sed -e "s|^backend = .*|backend = mlx|" \
    -e "s|^mlx_base_url = .*|mlx_base_url = $MOCK_URL|" \
    -e "s|^mlx_autostart = .*|mlx_autostart = off|" \
    -e "s|^suggest = .*|suggest = history|" \
    "$REPO/err.conf" > "$ERR_CONF"
print -r -- "mock/model" > "$ERR_STATE_DIR/last-model"

# Run commands in a real interactive zsh (aliases + hooks active).
int_sh() {
  MOCK_URL="$MOCK_URL" zsh -f -i 2>&1 <<EOF
PROMPT=''; RPROMPT=''; PS1=''
source "$REPO/err-launcher.zsh"
$1
EOF
}

# Non-interactive runner: no prompt, no ZLE.
cmd_out() {
  zsh -f -c "source '$REPO/err-launcher.zsh'; $1" 2>&1
}

print "environment: mock on $MOCK_URL, state in $ERR_STATE_DIR"

# ── 1. the menu ────────────────────────────────────────────────────────
# An interactive `err` needs a terminal; without one it prints the rows,
# which is exactly what a script (or this test) should see.
print "surface"
_out=$(cmd_out 'err')
contains "err new"           "$_out" "bare err shows the menu rows"
contains "err run <model>"   "$_out" "the menu lists err run"
contains "err cleanup"       "$_out" "the menu lists err cleanup"
not_contains "err settings"  "$_out" "err settings is gone (one config file)"
not_contains "err status"    "$_out" "err status folded into info"
not_contains "err chat"      "$_out" "err chat is gone"
not_contains "err tui"       "$_out" "err tui is gone"

_out=$(cmd_out 'err help')
contains "start a fresh session" "$_out" "err help opens the menu"
contains "err help" "$_out" "the menu lists err help as a typed command"
contains "0.602.0" "$(cmd_out 'err version')" "err version prints VERSION"

# ── 2. explain + ask reach the model ───────────────────────────────────
print "explain / ask"
_out=$(int_sh '_err_last_cmd="ls -la"; _err_last_exit=0; err wtf')
contains "A glob matches filenames." "$_out" "err wtf explains the last command"

_out=$(int_sh 'err "what is a glob"')
contains "A glob matches filenames." "$_out" "err <question> asks the backend"

# suggestion channel: history (default) must carry the command, buffer must not
_out=$(int_sh 'err "what is a glob" >/dev/null; builtin fc -ln -100 2>/dev/null | grep -q "^ls \*.txt" && print "SUGGEST_IN_HISTORY=yes" || print "SUGGEST_IN_HISTORY=no"')
contains "SUGGEST_IN_HISTORY=yes" "$_out" "suggestion lands in history for ↑"
_out=$(int_sh 'err "what is a glob" >/dev/null; print "BUF=[$BUFFER]"')
contains "BUF=[]" "$_out" "nothing is pre-filled into the prompt buffer"

last_has() { # $1 needle
  local _i
  for _i in {1..40}; do
    [[ -f "$_TMP/port.last" ]] && grep -qF -- "$1" "$_TMP/port.last" && return 0
    sleep 0.1
  done
  return 1
}
last_dump() { head -c 500 "$_TMP/port.last" 2>/dev/null }

# ── 3. the model gets what a command printed (the one surviving pipe) ──
print "captured output"
_out=$(int_sh 'print "PIPED_MARKER_42" | err wtf')
contains 'print "PIPED_MARKER_42"' "$_out" "piped err wtf explains the producing command"
not_contains "| err wtf" "$_out" "the | err stage is not recorded as the command"
last_has "PIPED_MARKER_42" && ok "piped output reached the model" \
  || fail "piped output reached the model" "last request: $(last_dump)"

_out=$(int_sh 'print "CTX_MARKER_9" >/dev/null; err "what just happened" >/dev/null')
last_has "the command I just ran" && ok "a question carries the last command as context" \
  || fail "a question carries the last command as context" "last request: $(last_dump)"

# ── 4. the last model you ran is the one err answers from ─────────────
print "model resolution"
print -r -- "mock/model" > "$ERR_STATE_DIR/last-model"
_out=$(int_sh 'err "still there"')
contains "A glob matches filenames." "$_out" "err still answers after a round-trip"

# ── 5. guard rails ─────────────────────────────────────────────────────
print "guard rails"
# A dropped verb is no longer reserved, so `err runs` is just a question now.
_out=$(cmd_out '_err_last_cmd=""; _err_consumed=1; err wtf; print "RC=$?"')
contains "no command to explain." "$_out" "err wtf with nothing recorded explains that"
contains "RC=1" "$_out" "err wtf exits 1 when there is nothing to explain"

_out=$(cmd_out 'errc true; print "RC=$?"')
contains "RC=127" "$_out" "errc is gone"

# ── 6. engine verbs that only read ────────────────────────────────────
print "engine read-only verbs"
_out=$(cmd_out 'err list')
contains "$FAKE_MODEL" "$_out" "err list finds the fake model"
not_contains ".safetensors" "$_out" "err list prints ids only"

_out=$(cmd_out 'err info --json; print "RC=$?"')
# :11500 is machine-global: a live model (or none) is a valid answer, but the
# shape must always be one of the two documented forms.
if print -r -- "$_out" | grep -q '"model"'; then
  contains '"base_url"' "$_out" "info --json names the base_url"
elif print -r -- "$_out" | grep -q 'null'; then
  ok "info --json is null when nothing serves :11500"
else
  fail "info --json reports the server or null" "$_out"
fi

_out=$(cmd_out 'err download')
contains "err download Hugging Face ID" "$_out" "err download offers the free-text id"

_out=$(cmd_out 'err cleanup')
contains "err cleanup kv-cache" "$_out" "err cleanup lists the caches"
[[ -d "$ERR_STATE_DIR" ]] && ok "listing the caches deleted nothing"

# One config file, in state, seeded from the template on first use.
_cfgdir="$_TMP/cfgstate"
_out=$(env -u ERR_CONF ERR_STATE_DIR="$_cfgdir" ERR_HUB_DIR="$_TMP/hub" \
  zsh -c "source '$REPO/err-launcher.zsh'; err config" 2>&1)
[[ -f "$_cfgdir/err.conf" ]] && ok "err config seeds \$ERR_STATE_DIR/err.conf" \
  || fail "err config seeds \$ERR_STATE_DIR/err.conf" "$_out"
grep -q '^temperature = ' "$_cfgdir/err.conf" 2>/dev/null \
  && ok "the seeded config carries one shared temperature" \
  || fail "the seeded config carries one shared temperature" "$(head -3 "$_cfgdir/err.conf" 2>/dev/null)"
_out=$(env -u ERR_CONF ERR_STATE_DIR="$_cfgdir" ERR_HUB_DIR="$_TMP/hub" \
  zsh -c "source '$REPO/err-launcher.zsh'; err config" 2>&1)
contains "err.conf" "$_out" "err config names the file it opens"

_out=$(cmd_out 'err remove no-such-org/nope-xyz; print "RC=$?"')
contains "not installed" "$_out" "err remove rejects an uninstalled model"
contains "RC=1" "$_out" "err remove exits 1 for an uninstalled model"
not_contains "permanently?" "$_out" "err remove does not ask to confirm a no-op"

# ── 7. a dead backend fails loudly, not silently ──────────────────────
print "failure modes"
_badconf="$_TMP/bad.conf"
sed -e "s|^backend = .*|backend = mlx|" \
    -e "s|^mlx_base_url = .*|mlx_base_url = http://127.0.0.1:9|" \
    -e "s|^mlx_autostart = .*|mlx_autostart = off|" "$ERR_CONF" > "$_badconf"
_out=$(ERR_CONF="$_badconf" int_sh 'err "anything"; print "RC=$?"')
contains "not reachable" "$_out" "unreachable backend says so"
contains "RC=1" "$_out" "unreachable backend exits 1"

# ── report ─────────────────────────────────────────────────────────────
print ""
if (( _FAILS )); then
  print "FAILED: $_FAILS  (passed $_PASSES)"
  exit 1
fi
print "smoke: all $_PASSES checks passed"
