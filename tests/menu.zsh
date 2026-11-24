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

fm_available() {
  local v major
  v=$(sw_vers -productVersion 2>/dev/null) || return 1
  major="${v%%.*}"
  [[ "$major" == <-> ]] && (( major >= 27 )) && command -v fm >/dev/null 2>&1
}

print "menu: $FAKE_MODEL in a throwaway hub"

# ── rows are commands ──────────────────────────────────────────────────
print "rendering"
# The submenus are drawn by err itself (`_err_pick`), with the TUI's look: no
# title row, `arr //` cursor. Off a terminal it prints the rows to stderr and
# aborts, which is what this sees.
_out=$({ no_servers; engine_rows dump run } 2>&1)
contains "err run $FAKE_MODEL" "$_out" "rows are the command you would type"
if fm_available; then
  contains "err run apple-fm" "$_out" "the Apple model is offered on macOS 27+"
else
  not_contains "apple-fm" "$_out" "the Apple model is hidden when macOS is older"
fi
not_contains "ARGS:" "$_out" "the picker does not shell out to a dialog tool"
not_contains "* " "$_out" "rows carry no default marker (the cursor is 'arr //')"

if print -r -- "$_out" | grep -qx 'err run'; then
  fail "no title row above the rows" "found a bare 'err run' line"
else
  ok "no title row above the rows"
fi

print "macOS gate"
# On macOS 26 or older the on-device model is not present: no row, and a run
# with no installed model must offer a download instead.
mkdir -p "$_TMP/macos26"
cat > "$_TMP/macos26/sw_vers" <<'EOF'
#!/bin/sh
echo 26.0
EOF
chmod +x "$_TMP/macos26/sw_vers"
_out=$({ PATH="$_TMP/macos26:$_TMP/bin:$PATH"; engine_rows dump run } 2>&1)
contains "err run $FAKE_MODEL" "$_out" "installed models are still offered on macOS 26"
not_contains "apple-fm" "$_out" "apple-fm is not offered on macOS 26"
mkdir -p "$_TMP/empty-hub"
_out=$({ PATH="$_TMP/macos26:$_TMP/bin:$PATH"; ERR_HUB_DIR="$_TMP/empty-hub" engine_rows dump run } 2>&1)
contains "err download" "$_out" "err run offers a download when no model is present"
not_contains "apple-fm" "$_out" "no Apple model row when none is present"

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
contains "err update" "$_out" "the menu offers err update"
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

# A narrow terminal must truncate rows, not let them wrap. A wrapped line is
# two physical lines, but the repaint moves up by the logical count, so the
# frame smears into the rows above it. A stub stty reports 40 columns.
mkdir -p "$_TMP/narrow"
cat > "$_TMP/narrow/stty" <<'EOF'
#!/bin/sh
echo "24 40"
EOF
chmod +x "$_TMP/narrow/stty"
_out=$( (sleep 1; printf 'j'; sleep 0.2; printf '\r') \
  | script -q /dev/null env ERR_PICK_DUMP= PATH="$_TMP/narrow:$PATH" \
      zsh "$REPO/err-models.zsh" helpmenu 2>/dev/null \
  | tr -d '\r' | sed -E $'s/\\x1b\\[[0-9;?]*[A-Za-z]//g' )
_long=$(print -r -- "$_out" | grep -E '^(arr //|       )' \
  | awk 'length($0) > 40 {print length($0)}' | sort -n | tail -1)
if [[ -z "$_long" ]]; then
  ok "a narrow window truncates rows instead of wrapping them"
else
  fail "a narrow window truncates rows instead of wrapping them" \
       "a painted line was $_long columns wide"
fi


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

# ── watchdog wiring ───────────────────────────────────────────────────
# `_err_arm_watchdog` existed for a release with no call site, so every `err
# run` model outlived its usefulness (one served for 25 hours). A real
# `err run` needs weights and :11500, so the guard is the call site itself: the
# engine's launch path must still arm it.
print "watchdog"
if grep -q '_err_arm_watchdog "$port" "$pid"' "$REPO/err-models.zsh"; then
  ok "the MLX launch path arms the idle watchdog"
else
  fail "the MLX launch path arms the idle watchdog" \
       "no _err_arm_watchdog call in the launch path"
fi
_out=$(zsh "$REPO/err-models.zsh" doctor 2>&1)
if print -r -- "$_out" | grep -qE '^  (ok|warn|fail) +watchdog '; then
  ok "doctor reports the idle watchdog"
else
  fail "doctor reports the idle watchdog" "$(print -r -- "$_out" | grep -c .) lines"
fi

# ── run flags ─────────────────────────────────────────────────────────
# `--idle` / `--keep` are launch options, not model ids. A bad spec must stop
# at the parser instead of being handed to the downloader.
print "run flags"
_out=$(engine_rows dump run --idle nonsense 2>&1); rc=$?
check "2" "$rc" "a bad --idle is a usage error"
contains "usage: err run" "$_out" "the usage line names --idle"
_out=$(engine_rows dump run --help 2>&1); rc=$?
check "0" "$rc" "err run --help is not a model id"
contains "usage: err run" "$_out" "--help prints the usage line"
# A dead HF endpoint makes a parsing regression fail fast instead of reaching
# for the network.
_out=$({ no_servers; HF_ENDPOINT="http://127.0.0.1:9" engine_rows dump run --keep } 2>&1)
contains "err run $FAKE_MODEL" "$_out" "--keep is a flag, not a model id"
not_contains "--keep" "$_out" "the flag is consumed, not echoed as a model"

# ── err update ────────────────────────────────────────────────────────
# `update` edits err's own source, so every test runs against a throwaway copy
# of the install tree with git/curl/sh stubbed. Nothing here may touch the real
# checkout, ~/.zshrc, or the network.
print "update"
_UPD="$_TMP/upd"
mkdir -p "$_UPD/lib" "$_UPD/bin" "$_UPD/home"
# Canonical path: the engine resolves $_ERR_SRC_DIR with ${0:A:h}, which turns
# /var/... into /private/var/... — the recorded argv must match that spelling.
_UPD="${_UPD:A}"
cp "$REPO/err-models.zsh" "$REPO/err.py" "$REPO/VERSION" "$REPO/err.conf" \
   "$REPO/err-curator.md" "$REPO/install.sh" "$_UPD/"
cp "$REPO"/lib/*.zsh "$REPO"/lib/*.py "$_UPD/lib/" 2>/dev/null

# The engine refuses to run headless without these; stub them so the test does
# not depend on the host having uv/mlx-vlm installed.
for _t in uvx mlx_vlm.server curl; do
  printf '#!/bin/sh\nexit 0\n' > "$_UPD/bin/$_t"
done
# git records its argv, reports a remote/branch, and "pulls" a new VERSION.
cat > "$_UPD/bin/git" <<EOF
#!/bin/sh
echo "git \$*" >> "$_UPD/calls"
case "\$*" in
  *remote*)    echo origin ;;
  *rev-parse*) echo main ;;
  *pull*)      echo 0.999.0 > "$_UPD/VERSION" ;;
esac
exit 0
EOF
# sh records what the installer was asked to run (and where it lives).
cat > "$_UPD/bin/sh" <<EOF
#!/bin/sh
echo "sh \$* ERR_DIR=\${ERR_DIR:-}" >> "$_UPD/calls"
exit 0
EOF
chmod +x "$_UPD/bin"/*

_upd() { # run the copied engine with the stubs in front of PATH
  # HOME too: the engine's legacy migration rewrites the launcher line in
  # ~/.zshrc, and a test copy of the tree must never repoint the real shell.
  : >| "$_UPD/calls"
  HOME="$_UPD/home" PATH="$_UPD/bin:$PATH" \
    zsh "$_UPD/err-models.zsh" "$@" 2>&1
}

# git checkout: fast-forward only, then the installer, then the version line.
mkdir -p "$_UPD/.git"
_out=$(_upd update)
_calls=$(<"$_UPD/calls")
contains "git -C $_UPD remote" "$_calls" "update asks the checkout for a remote"
contains "git -C $_UPD pull --ff-only" "$_calls" "update fast-forwards the git checkout"
contains "sh $_UPD/install.sh" "$_calls" "update re-runs the installer"
contains "err $(<"$REPO/VERSION") -> 0.999.0" "$_out" "update reports the version change"
contains "open a new terminal" "$_out" "update says the shell holds old code"

# Managed (curl) install: no git history, so install.sh refreshes the snapshot
# in place, pointed at the existing directory.
rm -rf "$_UPD/.git"
cp "$REPO/VERSION" "$_UPD/VERSION"
cat > "$_UPD/bin/curl" <<'EOF'
#!/bin/sh
# -o <file>: pretend the installer was downloaded
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
echo '#!/bin/sh' > "$out"
exit 0
EOF
chmod +x "$_UPD/bin/curl"
_out=$(_upd update)
_calls=$(<"$_UPD/calls")
not_contains "pull --ff-only" "$_calls" "a managed install never runs git"
contains "ERR_DIR=$_UPD" "$_calls" "install.sh is pointed at the existing install"
contains "is up to date" "$_out" "an unchanged version says so"

# A failed download must fail loudly, not report success.
cat > "$_UPD/bin/curl" <<'EOF'
#!/bin/sh
exit 22
EOF
chmod +x "$_UPD/bin/curl"
_out=$(_upd update); rc=$?
check "1" "$rc" "a failed download fails update"
contains "could not download install.sh" "$_out" "a failed download says so"
not_contains "is up to date" "$_out" "a failed download is not reported as up to date"

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
