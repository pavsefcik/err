#!/bin/zsh
set -e

PROJECT_DIR="${0:A:h}"
ZSHRC="$HOME/.zshrc"
MARKER="# err last-command explainer"
SOURCE_LINE="source \"$PROJECT_DIR/err.zsh\""

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is not installed. Install it from https://github.com/astral-sh/uv and re-run."
  exit 1
fi

if grep -Fq "$MARKER" "$ZSHRC" 2>/dev/null; then
  echo "err shim already present in $ZSHRC. Nothing to do."
else
  {
    echo ""
    echo "$MARKER"
    echo "$SOURCE_LINE"
  } >> "$ZSHRC"
  echo "Added err shim to $ZSHRC."
fi

if uv tool list 2>/dev/null | grep -q '^mlx-lm '; then
  echo "mlx-lm already installed as a uv tool."
else
  echo "Installing mlx-lm as a uv tool..."
  uv tool install --force mlx-lm
fi

uv tool update-shell >/dev/null 2>&1 || true

echo ""
echo "Done. Open a new terminal (or run 'source ~/.zshrc') and try: err"
