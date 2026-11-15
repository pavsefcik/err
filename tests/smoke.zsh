#!/usr/bin/env zsh
# End-to-end smoke tests: the REAL launcher, the REAL err.py, the REAL engine
# dispatch — against a mock OpenAI-compatible server, in an isolated state dir
# and an isolated err.conf. Nothing here needs `fm`, models, or network.
#
# These assert what the USER sees (output, exit code, err.conf, history), not
# that an internal function was called. Every bug found so far lived in that gap.
#
# Usage: zsh tests/smoke.zsh [-v]
emulate -L zsh
setopt pipefail
set -u

REPO="${0:A:h:h}"
VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

typeset -g _FAILS=0 _PASSES=0
typeset -g _TMP=""
typeset -g _MOCK_PID=""

cleanup() {
  [[ -n "$_MOCK_PID" ]] && kill "$_MOCK_PID" 2>/dev/null
  [[ -n "$_TMP" ]] && rm -rf "$_TMP"
}
trap cleanup EXIT INT TERM

ok()    { (( _PASSES++ )); print "  ok   $1" }
fail()  { (( _FAILS++ ));  print "  FAIL $1"; [[ -n "${2:-}" ]] && print "       $2" }
check() { # $1 expected, $2 actual, $3 label
  if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3" "expected: [$1]  actual: [$2]"; fi
}
contains() { # $1 needle, $2 haystack, $3 label
  if print -r -- "$2" | grep -qF -- "$1"; then ok "$3"; else
    fail "$3" "missing: [$1] in: [${2[1,300]}]"
  fi
}
not_contains() {
  if print -r -- "$2" | grep -qF -- "$1"; then
    fail "$3" "unexpected: [$1] in: [${2[1,300]}]"
  else ok "$3"; fi
}

# ── isolated environment ────────────────────────────────────────────────
_TMP=$(mktemp -d "${TMPDIR:-/tmp}/err-smoke.XXXXXX")
export ERR_STATE_DIR="$_TMP/state"
export ERR_CONF="$_TMP/err.conf"
export ERR_HUB_DIR="$_TMP/hub"          # keep the real HF cache out of this
export ERR_MLX_MODEL="mock/model"       # "the model lives on that server"
mkdir -p "$ERR_HUB_DIR"
mkdir -p "$ERR_STATE_DIR"

python3 "$REPO/tests/mock_serve.py" "$_TMP/port" >"$_TMP/mock.log" 2>&1 &
_MOCK_PID=$!
for _i in {1..100}; do [[ -s "$_TMP/port" ]] && break; sleep 0.1; done
if [[ ! -s "$_TMP/port" ]]; then
  print "FATAL: mock server did not start:" >&2
  cat "$_TMP/mock.log" >&2
  exit 1
fi
MOCK_URL="$(<"$_TMP/port")"

# A fake model in the throwaway hub, so the engine's read-only verbs have
# something to describe (never used to launch anything).
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

# Run commands in a real interactive zsh (aliases + hooks active), sharing the
# isolated env. $1 = script body.
int_sh() {
  MOCK_URL="$MOCK_URL" zsh -f -i 2>&1 <<EOF
PROMPT=''; RPROMPT=''; PS1=''
source "$REPO/err-launcher.zsh"
$1
EOF
}

# Non-interactive runner: no prompt, no ZLE — for anything that does not need
# the hooks (version, help, status, usage errors). Output is clean by design.
cmd_out() {
  zsh -f -c "source '$REPO/err-launcher.zsh'; $1" 2>&1
}

# Strip any escape sequences, just in case a prompt or colour leaks through.
plain() { print -r -- "$1" | perl -pe 's/\e\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r' }

print "environment: mock on $MOCK_URL, state in $ERR_STATE_DIR"

# ── 1. surface ──────────────────────────────────────────────────────────
print "surface"
_out=$(cmd_out 'err')
contains "TO ERR IS HUMAN."  "$_out" "bare err shows the help screen"
contains "err runs <model>"  "$_out" "help lists err runs under err run"
contains "err what | why"    "$_out" "help lists err what | why"
not_contains "err wtf"       "$_out" "help keeps err wtf hidden"

check "0.601.0" "$(cmd_out 'err version')" "err version prints VERSION"

# ── 2. explain + ask reach the model ───────────────────────────────────
print "explain / ask"
_out=$(int_sh '_err_last_cmd="ls -la"; _err_last_exit=0; err what')
contains "💡" "$_out" "err what explains the last command"
contains "A glob matches filenames." "$_out" "the explanation came from the configured backend"

_out=$(int_sh 'err "what is a glob"')
contains "A glob matches filenames." "$_out" "err <question> asks the backend"

# suggestion channel: history (default) must carry the command, buffer must not
_out=$(int_sh 'err "what is a glob" >/dev/null; builtin fc -ln -100 2>/dev/null | grep -q "^ls \*.txt" && print "SUGGEST_IN_HISTORY=yes" || print "SUGGEST_IN_HISTORY=no"')
contains "SUGGEST_IN_HISTORY=yes" "$_out" "suggestion lands in history for ↑"
_out=$(int_sh 'err "what is a glob" >/dev/null; print "BUF=[$BUFFER]"')
contains "BUF=[]" "$_out" "nothing is pre-filled into the prompt buffer"

# ── 3. backend switching actually changes what err uses ────────────────
print "backend switching"
_out=$(cmd_out 'err default apple-fm')
grep -q '^backend = fm' "$ERR_CONF" && ok "err default apple-fm writes backend=fm" \
  || fail "err default apple-fm writes backend=fm" "conf has: $(grep '^backend' "$ERR_CONF")"
contains "on-device Apple model" "$_out" "err default says what err will use"
_def=$(cat "$ERR_STATE_DIR/default-model" 2>/dev/null)
check "apple-fm" "$_def" "default-model recorded"

_out=$(cmd_out 'err default mock/model')
grep -q '^backend = mlx' "$ERR_CONF" && ok "err default <hf model> writes backend=mlx" \
  || fail "err default <hf model> writes backend=mlx" "conf has: $(grep '^backend' "$ERR_CONF")"

# Back to the mock before asking again (asking on the fm backend would start
# the real Apple server — never do that from a test).
cmd_out 'err default mock/model' >/dev/null
_out=$(int_sh 'err "still there"')
contains "A glob matches filenames." "$_out" "err still answers after the round-trip"

# ── 4. status tells the truth, including env overrides ────────────────
print "status / overrides"
_out=$(cmd_out 'err status')
contains "backend=mlx" "$_out" "status reports the effective backend"

_out=$(ERR_BACKEND=fm cmd_out 'err status')
contains "ERR_BACKEND overrides err.conf" "$_out" "status names a stray ERR_BACKEND"

_out=$(ERR_BACKEND=fm cmd_out 'err default mock/model')
contains "ERR_BACKEND=fm" "$_out" "switch/default warns when env overrides the file"

# ── 5. guard rails ─────────────────────────────────────────────────────
print "guard rails"
_out=$(cmd_out 'err runs apple-fm; print "RC=$?"')
contains "single on-device server" "$_out" "err runs refuses the Apple sentinel"
contains "RC=2" "$_out" "err runs exits 2 for the sentinel"

_out=$(cmd_out '_err_last_cmd=""; _err_consumed=1; err why; print "RC=$?"')
contains "No command to explain." "$_out" "err why with nothing recorded explains that"
contains "RC=1" "$_out" "err why exits 1 when there is nothing to explain"

_out=$(int_sh 'errc false >/dev/null 2>&1; print "RC=$?"')
contains "RC=1" "$_out" "errc preserves the command exit code"

_out=$(int_sh 'errc true >/dev/null 2>&1; print "DONE"; print "HASHELP=$(err | grep -c "TO ERR IS HUMAN")"')
contains "HASHELP=1" "$_out" "errc did not leave the help screen behind"

# ── 6. engine verbs that only read ────────────────────────────────────
print "engine read-only verbs"
_out=$(cmd_out 'err list')
contains "$FAKE_MODEL" "$_out" "err list finds the fake model"
not_contains ".safetensors" "$_out" "err list prints ids only"

_out=$(cmd_out 'err info mock-org/Fake-4bit')
contains "Installed:  true" "$_out" "err info reports installation"
contains "Size:" "$_out" "err info reports a size"

_out=$(cmd_out 'err curated')
contains "mlx-community/" "$_out" "err curated lists the bundled catalog"

_out=$(cmd_out 'err cache')
# the launcher canonicalizes ERR_STATE_DIR (":A"), so /var -> /private/var
_statedir_real=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$ERR_STATE_DIR")
contains "$_statedir_real" "$_out" "err cache reports the state dir"
contains "* = regenerable" "$_out" "err cache explains the regenerable marker"

_out=$(cmd_out 'err clean --all --dry-run')
contains "dry run" "$_out" "err clean --dry-run refuses to delete"
[[ -d "$ERR_STATE_DIR" ]] && ok "err clean --dry-run left the state dir alone"

# :11500 is machine-global, so this adapts: on a host that already serves a
# model the shape is asserted instead of the "nothing running" wording.
if lsof -nP -iTCP:11500 -sTCP:LISTEN -t >/dev/null 2>&1; then
  # A delete must be validated before it asks for confirmation.
_out=$(cmd_out 'err remove no-such-org/nope-xyz; print "RC=$?"')
contains "not installed" "$_out" "err remove rejects an uninstalled model"
contains "RC=1" "$_out" "err remove exits 1 for an uninstalled model"
not_contains "permanently?" "$_out" "err remove does not ask to confirm a no-op"

_out=$(cmd_out 'err status --json; print "RC=$?"')
  contains '"base_url"' "$_out" "status --json exposes a base_url"
  contains '"model"' "$_out" "status --json exposes the model"
  _out=$(cmd_out 'err endpoint; print "RC=$?"')
  contains "http://127.0.0.1:11500/v1" "$_out" "err endpoint prints the base URL"
else
  # A delete must be validated before it asks for confirmation.
_out=$(cmd_out 'err remove no-such-org/nope-xyz; print "RC=$?"')
contains "not installed" "$_out" "err remove rejects an uninstalled model"
contains "RC=1" "$_out" "err remove exits 1 for an uninstalled model"
not_contains "permanently?" "$_out" "err remove does not ask to confirm a no-op"

_out=$(cmd_out 'err status --json; print "RC=$?"')
  contains "null" "$_out" "status --json is null when nothing serves :11500"
  contains "RC=1" "$_out" "status --json exits 1 when nothing is running"
  _out=$(cmd_out 'err endpoint; print "RC=$?"')
  contains "no model running" "$_out" "err endpoint says when nothing is running"
fi

_out=$(cmd_out "err help | grep -m1 'err v0.601.0'")
contains "err v0.601.0" "$_out" "err help prints the banner"
check "$(cmd_out 'err help')" "$(cmd_out 'err -h')" "err help and err -h agree"

# The README fenced block is the user-facing copy of `err help`. Drift here is
# how a documented verb stops existing (or a new one stays invisible).
_help=$(cmd_out 'err help' | sed '/^[[:space:]]*$/d')
_readme=$(awk '/^err v0\.601\.0 \/\//{f=1} f{print} /stops offering it\.$/{f=0}' "$REPO/README.md" | sed '/^[[:space:]]*$/d')
if [[ -z "$_readme" ]]; then
  fail "README help block found" "no fenced block starting with 'err v0.601.0 //'"
elif [[ "$_help" == "$_readme" ]]; then
  ok "README help block matches err help"
else
  fail "README help block matches err help" "$(diff <(print -r -- "$_help") <(print -r -- "$_readme") | head -6)"
fi

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
