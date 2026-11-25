#!/usr/bin/env bash
# Build a release .app bundle. Optionally install to ~/Applications.
#
# Usage:
#   ./lib/build_app.sh
#   ./lib/build_app.sh --install
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=project.sh
source "$SCRIPT_DIR/project.sh"
swift_scripts_init

# shellcheck source=ensure_xcode_toolchain.sh
source "$SCRIPT_DIR/ensure_xcode_toolchain.sh"
swift_scripts_use_xcode_toolchain
echo "==> Using Xcode: $DEVELOPER_DIR"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Stopping running instances (so the new build actually starts)"
osascript -e "quit app \"$APP_DISPLAY_NAME\"" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "==> Syncing bundled resources"
swift_scripts_sync_changelog_artifacts

if [[ -n "$LOCALIZATIONS_XCSTRINGS" ]]; then
  echo "==> Compiling localizations"
  chmod +x "$SCRIPT_DIR/compile_localizations.sh"
  "$SCRIPT_DIR/compile_localizations.sh"
  "$SCRIPT_DIR/compile_localizations.sh" --check
fi

echo "==> Building release binary"
swift build -c release
BIN="$ROOT/.build/release/$APP_NAME"
MODULE_BUNDLE="$ROOT/.build/release/${APP_NAME}_${APP_NAME}.bundle"
if [[ ! -d "$MODULE_BUNDLE" ]]; then
  MODULE_BUNDLE="$(find "$ROOT/.build" -name "${APP_NAME}_${APP_NAME}.bundle" -type d | head -1)"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
if [[ -d "$MODULE_BUNDLE" ]]; then
  cp -R "$MODULE_BUNDLE" "$APP/Contents/Resources/"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
echo "==> Compiling app icons (Assets.car + AppIcon.icns)"
ICON_ASSETSET="$ROOT/Resources/Assets.xcassets/AppIcon.appiconset"
ACTOOL_OUT="$(mktemp -d)"
cleanup_actool() { rm -rf "$ACTOOL_OUT"; }
trap cleanup_actool EXIT
rm -f "$ICON_ASSETSET"/icon_*.png
cp "$ROOT/Resources/AppIcon.iconset"/icon_*.png "$ICON_ASSETSET/"
xcrun actool --compile "$ACTOOL_OUT" "$ROOT/Resources/Assets.xcassets" \
  --app-icon AppIcon \
  --platform macosx \
  --minimum-deployment-target "$MACOS_DEPLOYMENT_TARGET" \
  --output-partial-info-plist "$ACTOOL_OUT/partial.plist" \
  >/dev/null
cp "$ACTOOL_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
cp "$ACTOOL_OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"
if [[ "$CHANGELOG_BILINGUAL" == 1 && -n "$CHANGELOG_EN" && -f "$ROOT/$CHANGELOG_EN" ]]; then
  cp "$ROOT/$CHANGELOG_EN" "$APP/Contents/Resources/$(basename "$CHANGELOG_EN")"
fi
xattr -cr "$APP" 2>/dev/null || true

echo "==> Code signing"
ENTITLEMENTS_PATH="$ROOT/$ENTITLEMENTS"

resolve_codesign_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "$CODESIGN_IDENTITY"
    return
  fi

  local dev_id dev
  dev_id="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
  if [[ -n "$dev_id" ]]; then
    echo "$dev_id"
    return
  fi

  dev="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ { print $2; exit }')"
  if [[ -n "$dev" ]]; then
    echo "$dev"
    return
  fi

  echo "-"
}

CODESIGN_IDENTITY="$(resolve_codesign_identity)"
USE_HARDENED_RUNTIME=false
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  USE_HARDENED_RUNTIME=true
fi

sign_target() {
  local target="$1"
  if [[ "$USE_HARDENED_RUNTIME" == true && -f "$ENTITLEMENTS_PATH" ]]; then
    codesign --force --options runtime \
      --sign "$CODESIGN_IDENTITY" \
      --identifier "$BUNDLE_ID" \
      --entitlements "$ENTITLEMENTS_PATH" \
      "$target"
  elif [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$target"
  else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$target"
  fi
}

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "   Ad-hoc signing (no Developer ID / Apple Development certificate found)"
else
  echo "   Using code signing identity: $CODESIGN_IDENTITY"
fi

while IFS= read -r -d '' nested; do
  if [[ -f "$nested/Contents/Info.plist" ]]; then
    sign_target "$nested"
  fi
done < <(find "$APP/Contents" \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" \) -type d -print0 2>/dev/null)

sign_target "$APP/Contents/MacOS/$APP_NAME"
sign_target "$APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  echo "==> Registering app with Launch Services (refreshes icon in Finder & Settings)"
  "$LSREGISTER" -f -R -trusted "$APP" >/dev/null 2>&1 || true
fi
touch "$APP"

TEAM_ID="$(codesign -dv "$APP" 2>&1 | awk -F= '/TeamIdentifier/ { print $2 }')"
if [[ "$TEAM_ID" == "not set" ]]; then
  echo ""
  if security find-certificate -a -c "Apple Development" -p >/dev/null 2>&1 \
    || security find-certificate -a -c "Developer ID Application" -p >/dev/null 2>&1; then
    echo "   Сертификат найден в связке ключей, но приватный ключ отсутствует"
    echo "   (security find-identity: 0 valid identities)."
    echo "   Удалите сертификат в Xcode → Settings → Accounts → Manage Certificates"
    echo "   и создайте заново: + → Apple Development (на этом Mac)."
  else
    echo "   Ad-hoc сборка (TeamIdentifier=not set)."
    echo "   На macOS 26+ в «Системные настройки → Уведомления» будет заглушка вместо иконки,"
    echo "   пока приложение не подписано Apple Development или Developer ID."
    echo "   Создайте сертификат: Xcode → Settings → Accounts → Manage Certificates."
  fi
fi

echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  INSTALL_DIR="$HOME/Applications"
  INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
  LEGACY_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

  echo "==> Installing to $INSTALLED_APP"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALLED_APP"
  cp -R "$APP" "$INSTALLED_APP"

  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f -R -trusted "$INSTALLED_APP" >/dev/null 2>&1 || true
  fi

  echo "==> Removing legacy LaunchAgent (if any)"
  launchctl bootout "gui/$(id -u)" "$LEGACY_PLIST" 2>/dev/null || \
    launchctl unload "$LEGACY_PLIST" 2>/dev/null || true
  rm -f "$LEGACY_PLIST"

  echo "==> Starting installed app"
  open "$INSTALLED_APP"
  echo "Installed. Enable autostart in Settings → About if needed."
fi
