#!/bin/zsh
set -e

PROJECT_DIR="${0:A:h}"
ZSHRC="$HOME/.zshrc"
MARKER="# err last-command explainer"
SOURCE_LINE="source \"$PROJECT_DIR/err-launcher.zsh\""

if ! command -v fm >/dev/null 2>&1; then
  echo "Apple Foundation Models CLI (fm) is not installed. It ships with macOS 27 or later."
  echo "Please update your macOS."
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

echo ""
echo "Done. Open a new terminal (or run 'source ~/.zshrc') and try: err"
