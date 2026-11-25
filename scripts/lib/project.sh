#!/usr/bin/env bash
# Resolve this repo root (ROOT) and load scripts/config.sh.

swift_scripts_resolve_paths() {
  LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SCRIPTS_DIR="$(cd "$LIB_DIR/.." && pwd)"
  CHANGELOG_DIR="$LIB_DIR/changelog"
  ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
}

swift_scripts_apply_config() {
  set -a
  # shellcheck source=/dev/null
  source "$1"
  set +a

  : "${APP_NAME:?APP_NAME must be set in scripts/config.sh}"
  : "${BUNDLE_ID:?BUNDLE_ID must be set in scripts/config.sh}"
  : "${RELEASE_REPO:?RELEASE_REPO must be set in scripts/config.sh}"
  : "${SOURCES_MODULE_DIR:?SOURCES_MODULE_DIR must be set in scripts/config.sh}"

  SWIFT_MODULE="${SWIFT_MODULE:-$APP_NAME}"
  APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-$APP_NAME}"
  RELEASE_APP_NAME="${RELEASE_APP_NAME:-$APP_DISPLAY_NAME}"
  ENTITLEMENTS="${ENTITLEMENTS:-Resources/${APP_NAME}.entitlements}"
  DMG_VOLUME_NAME="${DMG_VOLUME_NAME:-$APP_DISPLAY_NAME}"
  MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-15.0}"
  CHANGELOG_EN="${CHANGELOG_EN:-}"
  BUNDLED_CHANGELOG="${BUNDLED_CHANGELOG:-$SOURCES_MODULE_DIR/Bundled/CHANGELOG.md}"
  BUNDLED_CHANGELOG_EN="${BUNDLED_CHANGELOG_EN:-$SOURCES_MODULE_DIR/Bundled/CHANGELOG.en.md}"
  CHANGELOG_DATA_SWIFT="${CHANGELOG_DATA_SWIFT:-$SOURCES_MODULE_DIR/Domain/ChangelogData.swift}"
  LOCALIZATIONS_XCSTRINGS="${LOCALIZATIONS_XCSTRINGS:-}"
  CHANGELOG_BILINGUAL="${CHANGELOG_BILINGUAL:-0}"

  SOURCE_REPO="${SOURCE_REPO:-}"

  export ROOT SCRIPTS_DIR LIB_DIR CHANGELOG_DIR
  export APP_NAME SWIFT_MODULE APP_DISPLAY_NAME RELEASE_APP_NAME
  export BUNDLE_ID SOURCE_REPO RELEASE_REPO SOURCES_MODULE_DIR ENTITLEMENTS DMG_VOLUME_NAME
  export MACOS_DEPLOYMENT_TARGET CHANGELOG_EN BUNDLED_CHANGELOG BUNDLED_CHANGELOG_EN
  export CHANGELOG_DATA_SWIFT LOCALIZATIONS_XCSTRINGS CHANGELOG_BILINGUAL
}

swift_scripts_load_config() {
  local config="$SCRIPTS_DIR/config.sh"
  if [[ ! -f "$config" ]]; then
    echo "error: missing $config" >&2
    exit 1
  fi
  swift_scripts_apply_config "$config"
}

swift_scripts_build_release_git_files() {
  RELEASE_GIT_FILES=(
    Resources/Info.plist
    CHANGELOG.md
  )
  if [[ -n "$CHANGELOG_EN" ]]; then
    RELEASE_GIT_FILES+=("$CHANGELOG_EN")
  fi
  RELEASE_GIT_FILES+=("$BUNDLED_CHANGELOG")
  if [[ "$CHANGELOG_BILINGUAL" == 1 ]]; then
    RELEASE_GIT_FILES+=("$BUNDLED_CHANGELOG_EN")
  fi
  RELEASE_GIT_FILES+=("$CHANGELOG_DATA_SWIFT")
}

swift_scripts_sync_changelog_artifacts() {
  if [[ ! -f "$ROOT/CHANGELOG.md" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$ROOT/$BUNDLED_CHANGELOG")"
  cp "$ROOT/CHANGELOG.md" "$ROOT/$BUNDLED_CHANGELOG"
  if [[ "$CHANGELOG_BILINGUAL" == 1 && -n "$CHANGELOG_EN" && -f "$ROOT/$CHANGELOG_EN" ]]; then
    mkdir -p "$(dirname "$ROOT/$BUNDLED_CHANGELOG_EN")"
    cp "$ROOT/$CHANGELOG_EN" "$ROOT/$BUNDLED_CHANGELOG_EN"
  fi
  python3 "$LIB_DIR/generate_changelog_data.py"
}

swift_scripts_init() {
  swift_scripts_resolve_paths
  swift_scripts_load_config
  cd "$ROOT"
}

swift_scripts_init_with_args() {
  SWIFT_SCRIPTS_ARGS=("$@")
  swift_scripts_init
}

# Bash 3.2 + set -u treats an empty "${arr[@]}" as unbound — use this instead.
swift_scripts_apply_remaining_args() {
  if ((${#SWIFT_SCRIPTS_ARGS[@]} > 0)); then
    set -- "${SWIFT_SCRIPTS_ARGS[@]}"
  else
    set --
  fi
}
