#!/usr/bin/env bash
# Build a styled read-only .dmg with drag-to-Applications layout.
#
# Usage:
#   ./lib/create_dmg.sh <MyApp.app> <output.dmg>
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <app-bundle> <output.dmg>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=project.sh
source "$SCRIPT_DIR/project.sh"
swift_scripts_init

APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTPUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"

DMG_PYTHON=""

ensure_dmgbuild() {
  local venv="$SCRIPTS_DIR/.venv"
  if [[ ! -x "$venv/bin/python" ]]; then
    echo "==> Creating Python environment for dmgbuild"
    python3 -m venv "$venv"
  fi
  DMG_PYTHON="$venv/bin/python"
  if "$DMG_PYTHON" -c "import dmgbuild" 2>/dev/null; then
    return 0
  fi
  echo "==> Installing dmgbuild (Python, one-time)"
  "$DMG_PYTHON" -m pip install dmgbuild -q
  if ! "$DMG_PYTHON" -c "import dmgbuild" 2>/dev/null; then
    echo "error: dmgbuild is required. The installer uses $venv" >&2
    exit 1
  fi
}

if [[ ! -d "$APP" ]]; then
  echo "App bundle not found: $APP" >&2
  exit 1
fi

ensure_dmgbuild

echo "==> Building styled DMG"
rm -f "$OUTPUT"
"$DMG_PYTHON" -m dmgbuild \
  -s "$SCRIPT_DIR/dmg_settings.py" \
  -Dapp="$APP" \
  "$DMG_VOLUME_NAME" \
  "$OUTPUT"

echo "Created: $OUTPUT"
