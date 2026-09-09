#!/usr/bin/env bash
# Creates a private Python environment for this program and installs what it
# needs. Nothing is installed system-wide, so it cannot break your Mac's Python
# or Homebrew. Run this once.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$DIR/.venv"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 is not installed. Get it from https://www.python.org/downloads/"
    exit 1
fi

if [ ! -d "$VENV" ]; then
    echo "Creating a private Python environment in $VENV"
    python3 -m venv "$VENV"
fi

echo "Installing image libraries (this takes a minute the first time)..."
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet -r "$DIR/requirements.txt"

echo
echo "Setup complete. Convert photos with:"
echo "    $DIR/heif2jpeg /path/to/your/photos"
