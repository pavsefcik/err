#!/usr/bin/env zsh
# Menu tests: the real picker code in err-models.zsh, driven by a fake `gum`.
#
# Why: `gum choose` renders on stderr and needs a TTY. A redirect or a
# non-tty hid the whole menu once (err run did "nothing"). These tests assert
# the rows, the header, the default marker, and that a cancel aborts instead of
# falling through to another menu — without needing a terminal or a model.
#
# Usage: zsh tests/menu.zsh [-v]
emulate -L zsh
set -u

REPO="${0:A:h:h}"
typeset -g _FAILS=0 _PASSES=0 _TMP=""

cleanup() { [[ -n "$_TMP" ]] && rm -rf "$_TMP" }
trap cleanup EXIT INT TERM

ok()    { (( _PASSES++ )); print "  ok   $1" }
fail()  { (( _FAILS++ ));  print "  FAIL $1"; [[ -n "${2:-}" ]] && print "       $2" }
check() { if [[ "$1" == "$2" ]]; then ok "$3"; else fail "$3" "expected [$1] actual [$2]"; fi }
contains() {
  if print -r -- "$2" | grep -qF -- "$1"; then ok "$3"; else fail "$3" "missing [$1]"; fi
}

_TMP=$(mktemp -d "${TMPDIR:-/tmp}/err-menu.XXXXXX")
export ERR_STATE_DIR="$_TMP/state"
export ERR_CONF="$_TMP/err.conf"
export ERR_HUB_DIR="$_TMP/hub"
export ERR_MLX_MODEL=""
mkdir -p "$ERR_STATE_DIR" "$_TMP/bin"

# A fake model in a fake hub so the list has more than one row.
FAKE_MODEL="mock-org/Fake-4bit"
mkdir -p "$ERR_HUB_DIR/models--mock-org--Fake-4bit/snapshots/rev"
: > "$ERR_HUB_DIR/models--mock-org--Fake-4bit/snapshots/rev/model.safetensors"
print -r -- '{"model_type":"qwen2","architectures":["Qwen2ForCausalLM"]}' \
  > "$ERR_HUB_DIR/models--mock-org--Fake-4bit/snapshots/rev/config.json"

cat > "$_TMP/bin/gum" <<'FAKE'
#!/bin/sh
# Fake gum: `choose` reads the list from stdin.
#   FAKE_GUM_MODE=dump        print args+list to stderr, exit 1  (like esc)
#   FAKE_GUM_MODE=pick-first  print the first row to stdout
#   FAKE_GUM_MODE=pick-last   print the last row to stdout
[ "$1" = "choose" ] || exit 0
list=$(cat)
case "${FAKE_GUM_MODE:-dump}" in
  dump)       printf 'ARGS: %s\n' "$*" >&2
              printf '%s\n' "$list" >&2
              exit 1 ;;
  pick-first) printf '%s\n' "$list" | head -n1 ;;
  pick-last)  printf '%s\n' "$list" | tail -n1 ;;
esac
FAKE
chmod +x "$_TMP/bin/gum"

sed -e "s|^backend = .*|backend = mlx|" \
    -e "s|^suggest = .*|suggest = history|" \
    "$REPO/err.conf" > "$ERR_CONF"

engine() { PATH="$_TMP/bin:$PATH" zsh "$REPO/err-models.zsh" "$@"; }
engine_gum() { # $1 = FAKE_GUM_MODE, rest = args
  local mode="$1"; shift
  PATH="$_TMP/bin:$PATH" FAKE_GUM_MODE="$mode" zsh "$REPO/err-models.zsh" "$@"
}

print "menu: $FAKE_MODEL in a throwaway hub"

# ── rendering ──────────────────────────────────────────────────────────
print "rendering"
_out=$(engine_gum dump run 2>&1)
contains "ARGS:" "$_out" "the picker calls gum"
contains "--header.foreground 255" "$_out" "header is white, not gum's purple"
contains "--height 20" "$_out" "list height is set"
contains "apple-fm" "$_out" "the Apple model is offered"
contains "$FAKE_MODEL" "$_out" "installed models are offered"

# Header must start on its own line: the argument begins with a newline, so the
# text before the question is empty.
if print -r -- "$_out" | awk '/^ARGS:/{n=NR} /Start which model\?/{print (NR==n ? "same-line" : "new-line")}' \
   | grep -q new-line; then
  ok "header starts on a new line"
else
  fail "header starts on a new line" "$(print -r -- "$_out" | grep -m1 -A1 '^ARGS:')"
fi

# Every row must begin with exactly two columns ('* ' or '  ') so the list
# lines up under gum's cursor.
_rows=$(print -r -- "$_out" | grep -E '^(apple-fm|\* |  )' | sed 's/^\(..\).*/\1/')
_bad=$(print -r -- "$_rows" | grep -vc '^\(\* \|  \)$')
check "0" "$_bad" "every row starts with a 2-column marker"

# ── default marker ─────────────────────────────────────────────────────
print "default marker"
# backend = fm means the Apple model is err's default, with no explicit choice
sed -i '' 's/^backend = .*/backend = fm/' "$ERR_CONF"
rm -f "$ERR_STATE_DIR/default-model"
_out=$(engine_gum dump run 2>&1)
if print -r -- "$_out" | grep -q '^\* apple-fm'; then
  ok "with backend=fm the Apple model is starred and first"
else
  fail "with backend=fm the Apple model is starred and first"
fi

sed -i '' 's/^backend = .*/backend = mlx/' "$ERR_CONF"
print -r -- "$FAKE_MODEL" > "$ERR_STATE_DIR/default-model"
_out=$(engine_gum dump run 2>&1)
if print -r -- "$_out" | grep -q "^\* $FAKE_MODEL"; then
  ok "the configured default is starred and pinned to the top"
else
  fail "the configured default is starred and pinned to the top"
fi
rm -f "$ERR_STATE_DIR/default-model"

# The download picker uses the same map; it must offer the catalog too.
_out=$(engine_gum dump download 2>&1)
contains "mlx-community/" "$_out" "err download offers curated models"
contains "GB RAM Tier Models" "$_out" "catalog rows carry their RAM tier"

# ── cancel must abort, not fall through ───────────────────────────────
print "cancel"
_out=$(engine_gum dump run 2>&1); rc=$?
check "1" "$rc" "esc exits non-zero"
case "$_out" in
  *"Nothing installed"*) fail "esc does not open a second menu" "saw 'Nothing installed'" ;;
  *) ok "esc does not open a second menu" ;;
esac
_out=$(engine_gum dump switch 2>&1)
contains "Switch to which model?" "$_out" "err switch asks with a menu"

# ── selection is mapped back to a model id ────────────────────────────
print "selection"
_out=$(engine_gum pick-first default 2>&1)
check "apple-fm" "$(cat "$ERR_STATE_DIR/default-model" 2>/dev/null)" \
  "choosing the first row records apple-fm"
grep -q '^backend = fm' "$ERR_CONF" && ok "choosing apple-fm repoints the backend to fm" \
  || fail "choosing apple-fm repoints the backend to fm" "conf: $(grep '^backend' "$ERR_CONF")"

_out=$(engine_gum pick-last default 2>&1)
check "$FAKE_MODEL" "$(cat "$ERR_STATE_DIR/default-model" 2>/dev/null)" \
  "choosing the last row records the installed model"
grep -q '^backend = mlx' "$ERR_CONF" && ok "choosing an MLX model repoints the backend to mlx" \
  || fail "choosing an MLX model repoints the backend to mlx" "conf: $(grep '^backend' "$ERR_CONF")"

print ""
if (( _FAILS )); then
  print "FAILED: $_FAILS  (passed $_PASSES)"
  exit 1
fi
print "menu: all $_PASSES checks passed"
