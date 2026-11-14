#!/bin/sh
# err installer — v0.601.0
#
# Usage (from an err checkout):
#   sh install.sh
#
# No Xcode Command Line Tools, no Homebrew, no compiler. It installs the tools
# err needs the brew-free way: uv from Astral's standalone installer, gum from
# its signed-off GitHub release binary (sha256 checked), and mlx-vlm as a uv
# tool. Anything already present on PATH (uv, gum, mlx_vlm.server) is reused,
# never reinstalled.
#
# Safe to re-run: every step skips what is already present, and the ~/.zshrc
# wiring is idempotent (it never appends a second launcher source or a second
# PATH line).
#
# Environment:
#   ERR_SKIP_HARDWARE_CHECK=1  skip the Apple Silicon / macOS 26 preflight
#   ERR_NO_ZSH=1               do not modify ~/.zshrc
#   ERR_DRY_RUN=1              preflight and print the plan, install nothing
#
# Flags:
#   --dry-run   print the plan without changing anything
#   --no-zsh    do not touch ~/.zshrc
#   --help

set -eu

# Track the step we are in so an abort always names it, even when the failing
# command did not go through die().
CURRENT_STEP="startup"
on_exit() {
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf '\ninstall.sh: FAILED during step: %s (exit %d)\n' "$CURRENT_STEP" "$_rc" >&2
  fi
}
trap on_exit EXIT

step() { CURRENT_STEP="$1"; printf '\n==> %s\n' "$1"; }
says() { printf '    %s\n' "$1"; }
warn() { printf '    ! %s\n' "$1"; }
die()  { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'USAGE'
err installer

usage: install.sh [--dry-run] [--no-zsh] [--help]

  --dry-run   print the plan without installing anything
  --no-zsh    do not modify ~/.zshrc
  --help      show this help

environment:
  ERR_SKIP_HARDWARE_CHECK=1   skip the Apple Silicon / macOS 26 preflight
  ERR_NO_ZSH=1                do not modify ~/.zshrc
  ERR_DRY_RUN=1               same as --dry-run
USAGE
}

# ---- Args → env --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) ERR_DRY_RUN=1; shift ;;
    --no-zsh)  ERR_NO_ZSH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done
export ERR_DRY_RUN ERR_NO_ZSH

# ---- PATH helpers ------------------------------------------------------------
# uv and gum both land in the user's bin dir (no brew involved). Put it on PATH
# for the rest of this script, and later for the user's shells.
LOCAL_BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
path_add() {
  case ":$PATH:" in
    *":$1:"*) : ;;
    *) PATH="$1:$PATH"; export PATH ;;
  esac
}
path_add "$LOCAL_BIN"

# ver_ge A B -> success when A >= B (dot-separated numeric versions).
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) {
      xi = (i <= na ? x[i] + 0 : 0)
      yi = (i <= nb ? y[i] + 0 : 0)
      if (xi > yi) exit 0
      if (xi < yi) exit 1
    }
    exit 0
  }'
}

# ---- Resolve the err checkout ------------------------------------------------
# This installer only works from a checkout: it wires the launcher that sits
# next to it. There is no tarball fetch step (unlike marv-mlx) because err's
# launcher, engine and config must stay together in one directory.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) \
  || die "could not resolve the directory install.sh is running from."
[ -f "$script_dir/err-launcher.zsh" ] || die \
  "err-launcher.zsh not found next to install.sh ($script_dir) — run install.sh from an err checkout."
repo_dir="$script_dir"

# ---- 1. Hardware preflight ---------------------------------------------------
# MLX is Apple-Silicon-only and the gum release binary below is Darwin/arm64.
# Fail here, early, instead of halfway through a tool install.
step "Checking hardware (Apple Silicon / macOS 26+)…"
if [ "${ERR_SKIP_HARDWARE_CHECK:-0}" = "1" ]; then
  says "skipped (ERR_SKIP_HARDWARE_CHECK=1)"
else
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || die \
    "err targets macOS — this system is $(uname -s). Set ERR_SKIP_HARDWARE_CHECK=1 to install anyway (the runtime still needs Apple Silicon to serve models)."

  arch="$(uname -m 2>/dev/null)"
  [ "$arch" = "arm64" ] || die \
    "err needs an Apple Silicon Mac (M-series); this machine reports '$arch'. Set ERR_SKIP_HARDWARE_CHECK=1 to install anyway."

  if ! osver="$(sw_vers -productVersion 2>/dev/null)"; then
    die "could not read the macOS version (sw_vers)."
  fi
  [ -n "$osver" ] || die "could not read the macOS version (sw_vers returned nothing)."
  ver_ge "$osver" "26.0" || die \
    "macOS $osver is too old — err requires macOS 26.0 or later. Upgrade and re-run."

  if mem_bytes="$(sysctl -n hw.memsize 2>/dev/null)"; then
    if [ -n "$mem_bytes" ]; then
      mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
      says "Apple Silicon — macOS $osver, ${mem_gb} GB unified memory"
      [ "$mem_gb" -ge 16 ] || warn "16 GB is recommended; ${mem_gb} GB can only run small models comfortably."
    else
      says "Apple Silicon — macOS $osver"
    fi
  else
    says "Apple Silicon — macOS $osver"
  fi
fi

# ---- 2. Explain layer (warn only) --------------------------------------------
# `fm` is the Apple Foundation Models CLI behind `err` / `err <question>`.
# The model manager half of err works without it, so a missing `fm` must not
# abort the install.
step "Checking the explain layer (Apple Foundation Models)…"
if command -v fm >/dev/null 2>&1; then
  says "fm present — explain / ask enabled"
else
  warn "Apple Foundation Models CLI (fm) not found."
  warn "  err can still run, manage and serve local MLX models."
  warn "  Explain / ask needs fm, which ships with macOS 27 or later."
fi

# ---- 3. uv (standalone binary; reused when already present) ------------------
step "Installing uv…"
if command -v uv >/dev/null 2>&1; then
  says "present ($(uv --version 2>/dev/null | head -n 1))"
elif [ "${ERR_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] curl https://astral.sh/uv/install.sh | UV_NO_MODIFY_PATH=1 sh"
else
  # Astral's installer drops a prebuilt binary — no compiler, no CLT, no brew.
  # UV_NO_MODIFY_PATH keeps PATH wiring in this script (one guarded line in
  # ~/.zshrc) instead of two competing writers. We download the script first
  # rather than piping curl into sh: a piped curl failure is invisible to a
  # POSIX shell without pipefail, and this step must fail loudly.
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/err-uv.XXXXXX")" \
    || die "could not create a temp directory for the uv installer."
  if ! curl -fsSL https://astral.sh/uv/install.sh -o "$_tmp/uv-install.sh"; then
    rm -rf "$_tmp"
    die "could not download the uv installer (https://astral.sh/uv/install.sh) — check your network and re-run."
  fi
  if ! UV_NO_MODIFY_PATH=1 sh "$_tmp/uv-install.sh"; then
    rm -rf "$_tmp"
    die "the uv installer failed — install uv by hand (https://docs.astral.sh/uv/getting-started/installation/) and re-run."
  fi
  rm -rf "$_tmp"
  path_add "$LOCAL_BIN"
  # The installer still uses ~/.cargo/bin when that legacy dir exists. Never
  # `source ~/.cargo/env`: sourcing a missing file under set -e aborts.
  if [ -x "$HOME/.cargo/bin/uv" ]; then
    path_add "$HOME/.cargo/bin"
  fi
  command -v uv >/dev/null 2>&1 || die \
    "uv installed but not on PATH (looked in $LOCAL_BIN and ~/.cargo/bin) — open a new terminal and re-run."
  says "installed $(uv --version 2>/dev/null | head -n 1)"
fi
if [ "${ERR_DRY_RUN:-0}" != "1" ]; then
  command -v uv >/dev/null 2>&1 || die \
    "uv is not on PATH — open a new terminal and re-run this script."
fi

# Ask uv where it puts tool executables (it is configurable: UV_TOOL_BIN_DIR,
# XDG_BIN_HOME, XDG_DATA_HOME) instead of assuming ~/.local/bin.
UV_TOOL_BIN="$(uv tool dir --bin 2>/dev/null || printf '%s/.local/bin' "$HOME")"
[ -n "$UV_TOOL_BIN" ] || UV_TOOL_BIN="$LOCAL_BIN"
path_add "$UV_TOOL_BIN"

# ---- 4. gum (release binary + sha256; reused when already present) -----------
# gum is what the TUI and prompts are built out of, and it is a standalone Go
# binary — there is no reason to drag Homebrew (and Xcode CLT) in for it.
GUM_VERSION="2.0.2"
GUM_SHA256="4777a69b1170b8db23c95d5889fb32186cfda1a3ac950d339aa17e3513633890"

gum_release_install() {
  _url="https://github.com/charmbracelet/gum/releases/download/v$GUM_VERSION/gum_${GUM_VERSION}_Darwin_arm64.tar.gz"
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/err-gum.XXXXXX")" || return 1
  if ! curl -fsSL "$_url" -o "$_tmp/gum.tar.gz"; then
    rm -rf "$_tmp"; return 1
  fi
  if command -v shasum >/dev/null 2>&1; then
    _got="$(shasum -a 256 "$_tmp/gum.tar.gz" | awk '{print $1}')"
  else
    _got="$(sha256sum "$_tmp/gum.tar.gz" | awk '{print $1}')"
  fi
  if [ "$_got" != "$GUM_SHA256" ]; then
    rm -rf "$_tmp"
    die "gum checksum mismatch (got $_got, want $GUM_SHA256) — refusing to install."
  fi
  if ! tar -xzf "$_tmp/gum.tar.gz" -C "$_tmp"; then
    rm -rf "$_tmp"; return 1
  fi
  _bin="$(find "$_tmp" -type f -name gum 2>/dev/null | head -n 1)"
  if [ -z "$_bin" ]; then
    rm -rf "$_tmp"; return 1
  fi
  mkdir -p "$LOCAL_BIN" || { rm -rf "$_tmp"; return 1; }
  if ! cp -f "$_bin" "$LOCAL_BIN/gum"; then
    rm -rf "$_tmp"; return 1
  fi
  chmod 755 "$LOCAL_BIN/gum"
  rm -rf "$_tmp"
  return 0
}

step "Installing gum…"
if command -v gum >/dev/null 2>&1; then
  says "present ($(gum --version 2>/dev/null | head -n 1))"
elif [ "${ERR_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] download gum $GUM_VERSION (Darwin/arm64, sha256 verified) -> $LOCAL_BIN/gum"
else
  gum_release_install || die \
    "could not download the gum release binary — check your network and re-run (or install gum yourself and re-run)."
  says "installed $GUM_VERSION -> $LOCAL_BIN/gum (sha256 verified)"
  path_add "$LOCAL_BIN"
  command -v gum >/dev/null 2>&1 || die \
    "gum is not on PATH after install (expected at $LOCAL_BIN/gum) — open a new terminal and re-run."
fi

# ---- 5. mlx-vlm as a uv tool (only when missing) -----------------------------
# err launches `mlx_vlm.server` for every model; `--with jinja2` supplies the
# chat templates the server needs. Never reinstall an existing tool env — that
# is how the self-healing startup path is designed to behave.
step "Installing mlx-vlm (with jinja2)…"
if command -v mlx_vlm.server >/dev/null 2>&1; then
  says "present (mlx_vlm.server on PATH)"
elif [ "${ERR_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] uv tool install mlx-vlm --with jinja2"
else
  _attempt=0
  until uv tool install mlx-vlm --with jinja2; do
    _attempt=$((_attempt + 1))
    if [ "$_attempt" -ge 3 ]; then
      die "uv tool install mlx-vlm failed after $_attempt attempts."
    fi
    says "mlx-vlm install failed — retrying (attempt $_attempt)…"
  done
  command -v mlx_vlm.server >/dev/null 2>&1 || die \
    "mlx_vlm.server is not available after install (expected in $UV_TOOL_BIN) — open a new terminal and re-run."
  says "installed mlx-vlm (with jinja2)"
fi

# ---- 6. Make sure uv's tool bin dir is on PATH -------------------------------
step "Checking PATH…"
if [ "${ERR_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] ensure $UV_TOOL_BIN and $LOCAL_BIN are on PATH"
elif command -v mlx_vlm.server >/dev/null 2>&1; then
  says "mlx_vlm.server on PATH ✓"
else
  die "mlx_vlm.server is not on PATH (uv tool dir --bin = $UV_TOOL_BIN) — open a new terminal and re-run."
fi

# Write one guarded line per dir so new shells see uv, gum and the tool shims.
# uv's own installer is told not to touch shell rc files, so this is the only
# writer. Idempotent: a dir already mentioned in ~/.zshrc is left alone.
wire_zsh_path() {
  _dir="$1"
  if [ "${ERR_NO_ZSH:-0}" = "1" ]; then
    says "skipped ~/.zshrc (ERR_NO_ZSH=1) — add: export PATH=\"$_dir:\$PATH\""
  elif [ -f "$HOME/.zshrc" ] && grep -qF "$_dir" "$HOME/.zshrc" 2>/dev/null; then
    says "$_dir already referenced in ~/.zshrc"
  elif [ "${ERR_DRY_RUN:-0}" = "1" ]; then
    says "[dry-run] append PATH line for $_dir to ~/.zshrc"
  else
    says "will append to ~/.zshrc:"
    printf '    | export PATH="%s:$PATH"\n' "$_dir"
    printf 'export PATH="%s:$PATH"\n' "$_dir" >> "$HOME/.zshrc"
    says "appended $_dir to ~/.zshrc"
  fi
}

step "Wiring PATH into ~/.zshrc…"
wire_zsh_path "$LOCAL_BIN"
if [ "$UV_TOOL_BIN" != "$LOCAL_BIN" ]; then
  wire_zsh_path "$UV_TOOL_BIN"
fi

# ---- 7. Wire the launcher into ~/.zshrc (idempotent) -------------------------
# The marker line makes the block findable; the source-line grep also catches a
# launcher wired by the older install.command, so the source is never added
# twice. The block is printed before it is appended.
step "Wiring err into ~/.zshrc…"
if [ "${ERR_NO_ZSH:-0}" = "1" ]; then
  says "skipped (ERR_NO_ZSH=1) — add manually: source \"$repo_dir/err-launcher.zsh\""
elif [ -f "$HOME/.zshrc" ] && grep -Fq 'err-launcher.zsh' "$HOME/.zshrc" 2>/dev/null; then
  says "launcher already wired in ~/.zshrc"
elif [ "${ERR_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] append to ~/.zshrc:"
  says "  # err (installed by install.sh)"
  says "  test -f \"$repo_dir/err-launcher.zsh\" && source \"$repo_dir/err-launcher.zsh\""
else
  says "will append to $HOME/.zshrc:"
  printf '    | # err (installed by install.sh)\n'
  printf '    | test -f "%s/err-launcher.zsh" && source "%s/err-launcher.zsh"\n' "$repo_dir" "$repo_dir"
  {
    printf '\n# err (installed by install.sh)\n'
    printf 'test -f "%s/err-launcher.zsh" && source "%s/err-launcher.zsh"\n' "$repo_dir" "$repo_dir"
  } >> "$HOME/.zshrc"
  says "appended launcher source to ~/.zshrc"
fi

# ---- 8. Final verification ---------------------------------------------------
step "Verifying…"
if [ "${ERR_DRY_RUN:-0}" = "1" ]; then
  says "[dry-run] nothing installed, nothing to verify"
else
  _ok=1
  for _c in uv gum mlx_vlm.server; do
    if ! command -v "$_c" >/dev/null 2>&1; then
      says "MISSING: $_c"
      _ok=0
    fi
  done
  [ "$_ok" -eq 1 ] || die "required tool(s) missing after install — re-run this script in a fresh shell."
  says "all tools present ✓"
fi

# ---- 9. Next steps -----------------------------------------------------------
step "Done. err is installed in $repo_dir"
if [ "${ERR_DRY_RUN:-0}" = "1" ]; then
  says "Dry run complete — nothing was installed."
  says "Re-run without --dry-run to apply."
  exit 0
fi
says "Open a NEW terminal (or run: source ~/.zshrc), then:"
says "  err                       explain / correct your last command"
says "  err <question>            ask anything"
says "  err download <model>      fetch a model from the HuggingFace Hub"
says "  err run <model>           serve it on http://127.0.0.1:11500/v1"
says "  err help                  full command list"
if ! command -v fm >/dev/null 2>&1; then
  warn "explain / ask is off until the Apple Foundation Models CLI (fm) is available."
  warn "model management and serving work without it."
fi
exit 0
