#!/usr/bin/env bash
# Compile xcstrings, then run swift (build/test/run/…).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/compile_localizations.sh"
exec swift "$@"
