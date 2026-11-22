#!/usr/bin/env zsh
# Menu tests: the real picker code in err-models.zsh, with no dialog toolkit.
#
# Why: err's menus paint on stderr and need a TTY. A redirect or a non-tty
# once hid the whole menu (err run did "nothing"). These tests assert the rows,
# the headers, the exclusions and that a cancel aborts instead of falling
# through — without a terminal or a model, and without launching one.
#
# err pickers off a terminal print their rows and abort; under a pty
# (engine_pty) ERR_PICK_DUMP makes them do the same instead of waiting for keys.
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
not_contains() {
  if print -r -- "$2" | grep -qF -- "$1"; then fail "$3" "unexpected [$1]"; else ok "$3"; fi
}

_TMP=$(mktemp -d "${TMPDIR:-/tmp}/err-menu.XXXXXX")
export ERR_STATE_DIR="$_TMP/state"
export ERR_CONF="$_TMP/err.conf"
export ERR_HUB_DIR="$_TMP/hub"
export ERR_MLX_MODEL=""
mkdir -p "$ERR_STATE_DIR" "$_TMP/bin"

# The developer's machine may be serving a model on :11500; a picker test must
# not depend on that. A stub lsof makes `_err_running` see no server, exactly
# what a clean CI sees. Tests that DO want a live server run without this.
cat > "$_TMP/bin/lsof" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$_TMP/bin/lsof"
no_servers() { export PATH="$_TMP/bin:$PATH"; }

# A fake model in a fake hub so the list has more than one row.
FAKE_MODEL="mock-org/Fake-4bit"
mkdir -p "$ERR_HUB_DIR/models--mock-org--Fake-4bit/snapshots/rev"
: > "$ERR_HUB_DIR/models--mock-org--Fake-4bit/snapshots/rev/model.safetensors"
print -r -- '{"model_type":"qwen2","architectures":["Qwen2ForCausalLM"]}' \
  > "$ERR_HUB_DIR/models--mock-org--Fake-4bit/snapshots/rev/config.json"

sed -e "s|^backend = .*|backend = mlx|" \
    -e "s|^suggest = .*|suggest = history|" \
    "$REPO/err.conf" > "$ERR_CONF"

# The help menu only opens the picker on a real terminal (a pipe gets the
# rows), so its interactive checks run under a pty.
engine_pty() { # $1 = tag (ignored), rest = args
  # ERR_PICK_DUMP: the pickers are interactive; a pty with nobody typing would
  # block, so they dump their rows and cancel instead.
  script -q /dev/null env ERR_PICK_DUMP=1 zsh "$REPO/err-models.zsh" "${@:2}"
}

engine_rows() { # $1 = tag (ignored), rest = args — rows come out of the picker
  zsh "$REPO/err-models.zsh" "${@:2}"
}

print "menu: $FAKE_MODEL in a throwaway hub"

# ── rows are commands ──────────────────────────────────────────────────
print "rendering"
# The submenus are drawn by err itself (`_err_pick`), with the TUI's look: no
# title row, `arr //` cursor. Off a terminal it prints the rows to stderr and
# aborts, which is what this sees.
_out=$({ no_servers; engine_rows dump run } 2>&1)
contains "err run $FAKE_MODEL" "$_out" "rows are the command you would type"
contains "err run apple-fm" "$_out" "the Apple model is offered"
not_contains "ARGS:" "$_out" "the picker does not shell out to a dialog tool"
not_contains "* " "$_out" "rows carry no default marker (the cursor is 'arr //')"

if print -r -- "$_out" | grep -qx 'err run'; then
  fail "no title row above the rows" "found a bare 'err run' line"
else
  ok "no title row above the rows"
fi

# ── read-only verbs don't open pickers or start anything ───────────────
print "read-only verbs"
# `err swap` needs something to swap from. :11500 is machine-global, so accept
# either the refusal (nothing running) or the rows (a server is up).
_out=$(engine_rows dump swap 2>&1)
if print -r -- "$_out" | grep -qF "err swap $FAKE_MODEL"; then
  ok "err swap offers swap rows when a model is running"
else
  contains "nothing is running" "$_out" "err swap refuses when nothing runs"
fi
# `err chat` / `err menu` / `err tui` are gone: they are not verbs any more.
_out=$(engine_rows dump chat 2>&1)
contains "unknown command 'chat'" "$_out" "err chat is no longer a verb"
# `err info` never starts a model: it shows the block or says nothing runs.
_out=$(engine_rows dump info 2>&1)
if print -r -- "$_out" | grep -q 'Model:'; then
  ok "err info shows the live model (a server is running on :11500)"
else
  contains "nothing is running" "$_out" "err info says when nothing runs"
fi
# Both verbs must say the same thing when there is nothing to show.
_swap="$({ no_servers; engine_rows dump swap } 2>&1)"
_info="$({ no_servers; engine_rows dump info } 2>&1)"
contains "nothing is running — start one with 'err run <model>'" "$_swap" "err swap names the next step"
contains "nothing is running — start one with 'err run <model>'" "$_info" "err info uses the same text as err swap"
# `err list` on a terminal is a look-only picker: the cursor moves, nothing
# is chosen. Off a terminal it stays bare ids for scripts.
_out=$(engine_pty dump list 2>&1)
contains "$FAKE_MODEL" "$_out" "err list opens the look-only cursor on a terminal"
not_contains "err info" "$_out" "err list does not open a menu"
_out=$(engine_rows dump list 2>&1)
not_contains "arr //" "$_out" "a piped err list stays bare ids"

print "remove excludes the Apple model"
_out=$(engine_rows dump remove 2>&1)
contains "err remove $FAKE_MODEL" "$_out" "err remove offers the installed model"
not_contains "apple-fm" "$_out" "apple-fm cannot be removed"

print "download"
# The catalog picker's "type an id" sentinel is a menu value, not a repo: it
# must be prompted for, never downloaded literally (`err download __hf_id__`
# is what the help menu re-dispatches). An empty answer cancels.
_out=$(ERR_TEST_INPUT= zsh "$REPO/err-models.zsh" download __hf_id__ 2>&1)
not_contains "downloading __hf_id__" "$_out" "the free-text sentinel is never downloaded"
_out=$(engine_rows dump download 2>&1)
contains "err download Hugging Face ID" "$_out" "a free-text Hugging Face id is offered"
# Content, not structure: read the bundled catalog, never a hardcoded repo.
_cat_id=$(grep -m1 -oE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' "$REPO/err-curator.md")
contains "err download $_cat_id" "$_out" "catalog rows are download commands"
# An installed model is not a download target any more.
_out=$(zsh "$REPO/err-models.zsh" download "$FAKE_MODEL" 2>&1)
contains "already downloaded" "$_out" "err download skips an installed model"

print "cleanup"
_out=$(engine_rows dump cleanup 2>&1)
contains "err cleanup kv-cache" "$_out" "every cache has a row"
contains "err cleanup all" "$_out" "a catch-all row clears everything"
not_contains "err cleanup chats" "$_out" "chats is no longer a cleanup row"
if print -r -- "$_out" | grep -qE 'err cleanup kv-cache +([0-9.]+ ?[KMG]?i?B|0 ?B)'; then
  ok "rows carry a size"
else
  fail "rows carry a size" "$(print -r -- "$_out" | grep 'cleanup kv-cache')"
fi
_out=$(ERR_TEST_INPUT=n zsh "$REPO/err-models.zsh" cleanup all 2>&1)
not_contains "err cleanup kv-cache" "$_out" "an explicit cleanup target skips the picker"

# ── the help menu ─────────────────────────────────────────────────────
print "help menu"
_out=$(engine_pty dump helpmenu 2>&1)
contains "local MLX LLM runner" "$_out" "the header names the version"
contains "Available commands:" "$_out" "the typed-only section has a heading"
contains "err 'question'" "$_out" "the question row is shown (typed, not picked)"
contains "err wtf" "$_out" "the wtf row is shown (typed, not picked)"
contains "err help" "$_out" "the help row is shown (typed, not picked)"
contains "err run <model>" "$_out" "the menu offers err run"
contains "err cleanup" "$_out" "the menu offers err cleanup"
contains "err record" "$_out" "the menu offers err record"
contains "err config" "$_out" "the menu offers err config"
not_contains "err settings" "$_out" "err settings is gone (one config file)"
not_contains "err status" "$_out" "err status folded into info"
# The description column is the menu's whole point: a row is the command plus
# what it does, and the plain path prints the same pairs.
if print -r -- "$_out" | grep -qE "err run <model> +start a model on port 11500"; then
  ok "rows carry the description on the right"
else
  fail "rows carry the description on the right" "$(print -r -- "$_out" | grep "err run" | head -2)"
fi

# The typed-only rows sit above the cursor's first row: Enter with no keys
# must pick `err new`, not reach the informational rows above it.
_out=$( (sleep 1; printf '\r') \
  | script -q /dev/null env ERR_PICK_DUMP= \
      zsh "$REPO/err-models.zsh" helpmenu 2>/dev/null \
  | tr -d '\r' | sed -E $'s/\\x1b\\[[0-9;?]*[A-Za-z]//g' \
  | awk -F'\t' 'NF>1 {print $1}' | tail -1)
_out="${_out//[[:cntrl:]]/}"
_out="${_out##*\^D}"
[[ "$_out" =~ '([a-zA-Z0-9_-]+)' ]] && _out="$match[1]"
check "new" "$_out" "the cursor starts at err new (not above it)"

# A chosen plain row comes back as the launcher's re-dispatch protocol. The
# menu is err's own now, so drive it with keys: 4x down = the `err info` row.
_out=$( (sleep 1; for i in {1..4}; do printf '\033[B'; sleep 0.05; done; printf '\r') \
  | script -q /dev/null env ERR_PICK_DUMP= \
      zsh "$REPO/err-models.zsh" helpmenu 2>/dev/null \
  | tr -d '\r' | sed -E $'s/\\x1b\\[[0-9;?]*[A-Za-z]//g' \
  | awk -F'\t' 'NF>1 {print $1}' | tail -1)
# `script` decorates the line with terminal noise (title sequences, a literal
# ^D + backspaces), so keep the trailing word run: the verb is the last token
# before the protocol tab.
_out="${_out//[[:cntrl:]]/}"
_out="${_out##*\^D}"          # the literal caret-D `script` leaves behind
[[ "$_out" =~ '([a-zA-Z0-9_-]+)' ]] && _out="$match[1]"
check "info" "$_out" "a picked row reports its verb"

# A piped `err` must print the rows, never drive a picker loop.
_out=$(zsh "$REPO/err-models.zsh" helpmenu 2>&1)
contains "err new" "$_out" "a non-tty help prints the rows"
contains "start a fresh session" "$_out" "the plain rows keep their descriptions"
contains "Available commands:" "$_out" "the plain help keeps the section heading"
contains "err 'question'" "$_out" "the question row is shown but not pickable"
contains "err wtf" "$_out" "the wtf row is shown but not pickable"
contains "err help" "$_out" "the help row is shown but not pickable"
not_contains "err chat" "$_out" "the chat row is gone"
not_contains "err tui" "$_out" "the tui row is gone"

# ── cancel must abort, not fall through ───────────────────────────────
print "cancel"
_out=$({ no_servers; engine_rows dump run } 2>&1); rc=$?
check "1" "$rc" "esc exits non-zero"
case "$_out" in
  *"Nothing installed"*) fail "esc does not open a second menu" "saw 'Nothing installed'" ;;
  *) ok "esc does not open a second menu" ;;
esac

print ""
if (( _FAILS )); then
  print "FAILED: $_FAILS  (passed $_PASSES)"
  exit 1
fi
print "menu: all $_PASSES checks passed"
