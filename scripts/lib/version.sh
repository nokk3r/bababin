#!/usr/bin/env bash
# Read or update app version in Resources/Info.plist.
#
# Usage:
#   ./lib/version.sh                 # print CFBundleShortVersionString
#   ./lib/version.sh print           # same
#   ./lib/version.sh build           # print CFBundleVersion
#   ./lib/version.sh set 1.3         # set both version and build
#   ./lib/version.sh bump patch
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=project.sh
source "$SCRIPT_DIR/project.sh"
swift_scripts_init

PLIST="$ROOT/Resources/Info.plist"
PLISTBUDDY="/usr/libexec/PlistBuddy"

if [[ ! -f "$PLIST" ]]; then
  echo "Info.plist not found: $PLIST" >&2
  exit 1
fi

read_key() {
  "$PLISTBUDDY" -c "Print :$1" "$PLIST" 2>/dev/null || true
}

write_key() {
  local key="$1"
  local value="$2"
  if "$PLISTBUDDY" -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
    "$PLISTBUDDY" -c "Set :$key $value" "$PLIST"
  else
    "$PLISTBUDDY" -c "Add :$key string $value" "$PLIST"
  fi
}

print_version() {
  read_key CFBundleShortVersionString
}

print_build() {
  read_key CFBundleVersion
}

check_version() {
  local version="${1#v}"
  local base suffix

  if [[ -z "$version" ]]; then
    echo "Invalid version: empty" >&2
    return 1
  fi

  if [[ "$version" == *..* ]] || [[ "$version" =~ \.$ ]] || [[ "$version" =~ -$ ]]; then
    echo "Invalid version: $version (malformed segments)" >&2
    return 1
  fi

  if [[ "$version" == *-* ]]; then
    base="${version%%-*}"
    suffix="${version#*-}"
  else
    base="$version"
    suffix=""
  fi

  if [[ ! "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Invalid version: $version (expected major.minor.patch, e.g. 1.2.6 or 1.3.0-beta.1)" >&2
    return 1
  fi

  if [[ -n "$suffix" && ! "$suffix" =~ ^[0-9A-Za-z][0-9A-Za-z.-]*$ ]]; then
    echo "Invalid version: $version (malformed prerelease suffix)" >&2
    return 1
  fi

  return 0
}

set_version() {
  local version="${1#v}"
  if ! check_version "$version"; then
    exit 1
  fi
  write_key CFBundleShortVersionString "$version"
  write_key CFBundleVersion "$version"
  echo "$version"
}

bump_version() {
  local kind="${1:-patch}"
  local current
  current="$(print_version)"
  if [[ -z "$current" ]]; then
    echo "Could not read current version from Info.plist" >&2
    exit 1
  fi

  python3 - "$current" "$kind" <<'PY'
import re
import sys

current = sys.argv[1]
kind = sys.argv[2]
base = re.split(r"-", current, maxsplit=1)[0]
parts = [int(x) for x in base.split(".") if x != ""]

if not parts:
    raise SystemExit(f"Invalid current version: {current}")

while len(parts) < 3:
    parts.append(0)

if kind == "patch":
    parts[2] += 1
elif kind == "minor":
    parts[1] += 1
    parts[2] = 0
elif kind == "major":
    parts[0] += 1
    parts[1] = 0
    parts[2] = 0
else:
    raise SystemExit(f"Unknown bump kind: {kind}")

while len(parts) > 2 and parts[-1] == 0:
    parts.pop()

print(".".join(str(part) for part in parts))
PY
}

preview_beta_version() {
  local current
  current="$(print_version)"
  if [[ -z "$current" ]]; then
    echo "Could not read current version from Info.plist" >&2
    exit 1
  fi

  python3 - "$current" <<'PY'
import re
import sys

current = sys.argv[1]
match = re.match(r"^(.*)-beta\.(\d+)$", current)
if match:
    base, number = match.group(1), int(match.group(2))
    print(f"{base}-beta.{number + 1}")
    raise SystemExit(0)

base = re.split(r"-", current, maxsplit=1)[0]
parts = [int(x) for x in base.split(".") if x != ""]
if not parts:
    raise SystemExit(f"Invalid current version: {current}")

while len(parts) < 3:
    parts.append(0)

parts[2] += 1

while len(parts) > 2 and parts[-1] == 0:
    parts.pop()

print(".".join(str(part) for part in parts) + "-beta.1")
PY
}

cmd="${1:-print}"

case "$cmd" in
  print|"")
    print_version
    ;;
  build)
    print_build
    ;;
  set)
    if [[ $# -lt 2 ]]; then
      echo "Usage: $0 set <version>" >&2
      exit 1
    fi
    set_version "$2"
    ;;
  bump)
    if [[ $# -lt 2 ]]; then
      echo "Usage: $0 bump patch|minor|major" >&2
      exit 1
    fi
    set_version "$(bump_version "$2")"
    ;;
  preview)
    if [[ $# -lt 2 ]]; then
      echo "Usage: $0 preview patch|minor|major" >&2
      exit 1
    fi
    bump_version "$2"
    ;;
  preview-beta)
    preview_beta_version
    ;;
  check)
    if [[ $# -lt 2 ]]; then
      echo "Usage: $0 check <version>" >&2
      exit 1
    fi
    check_version "$2"
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    echo "Usage: $0 [print|build|set <version>|check <version>|bump patch|minor|major|preview patch|minor|major|preview-beta]" >&2
    exit 1
    ;;
esac
