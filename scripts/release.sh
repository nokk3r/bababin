#!/usr/bin/env bash
# Bump version (optional), build the app, package a release zip, and
# optionally publish to the GitHub release repo (see scripts/config.sh).
#
# Usage:
#   ./release.sh
#   ./release.sh patch
#   ./release.sh minor --publish
#   ./release.sh --set 2.0
#   ./release.sh --no-bump
#   ./release.sh --no-bump --publish
#   ./release.sh patch --publish --beta
#   ./release.sh patch --old         # force stable Xcode.app for the build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/project.sh
source "$SCRIPT_DIR/lib/project.sh"
swift_scripts_init_with_args "$@"
swift_scripts_apply_remaining_args

# shellcheck source=lib/load_env.sh
source "$SCRIPT_DIR/lib/load_env.sh"
load_local_env

swift_scripts_build_release_git_files
BUMP=""
SET_VERSION=""
NO_BUMP=false
PUBLISH=false
BETA=false
SKIP_BUILD=false
PACKAGE_ONLY=false
INTERACTIVE=false
SKIP_CHANGELOG=false
USE_STABLE_XCODE=0
GENERATED_CHANGELOG=""
GENERATED_CHANGELOG_EN=""

init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_DIM=$'\033[2m'
    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_BLUE=$'\033[34m'
    COLOR_MAGENTA=$'\033[35m'
    COLOR_CYAN=$'\033[36m'
  else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_DIM=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_MAGENTA=""
    COLOR_CYAN=""
  fi
}

step() {
  printf '%b==>%b %b%s%b\n' "$COLOR_CYAN" "$COLOR_RESET" "$COLOR_BOLD" "$*" "$COLOR_RESET"
}

info() {
  printf '%b%s%b\n' "$COLOR_DIM" "$*" "$COLOR_RESET"
}

hint() {
  printf '%b%s%b\n' "$COLOR_DIM" "$*" "$COLOR_RESET"
}

label_value() {
  printf '  %b%s:%b  %b%s%b\n' "$COLOR_DIM" "$1" "$COLOR_RESET" "$COLOR_BOLD" "$2" "$COLOR_RESET"
}

warn_msg() {
  printf '%b⚠️  %s%b\n' "$COLOR_YELLOW" "$*" "$COLOR_RESET"
}

error_msg() {
  printf '%b%s%b\n' "$COLOR_RED" "$*" "$COLOR_RESET" >&2
}

success_msg() {
  printf '%b✓ %s%b\n' "$COLOR_GREEN" "$*" "$COLOR_RESET"
}

menu_item() {
  printf '  %b%s%b\n' "$COLOR_BLUE" "$*" "$COLOR_RESET"
}

divider() {
  printf '%b%s%b\n' "$COLOR_DIM" "════════════════════════════════════════" "$COLOR_RESET"
}

channel_colored() {
  if [[ "$BETA" == true ]]; then
    printf '%b%s%b' "$COLOR_MAGENTA" "Бета" "$COLOR_RESET"
  else
    printf '%b%s%b' "$COLOR_GREEN" "Стабильный" "$COLOR_RESET"
  fi
}

PREVIOUS_VERSION=""
RELEASE_IN_PROGRESS=false
RELEASE_SUCCEEDED=false
RELEASE_GH_PUBLISHED=false
RELEASE_GIT_COMMITTED=false
RELEASE_GIT_PUSHED=false
RELEASE_GIT_TAGGED=false
RELEASE_GIT_TAG_PUSHED=false
RELEASE_TAG=""

sync_changelog_artifacts() {
  swift_scripts_sync_changelog_artifacts
}

release_metadata_changed() {
  local file
  for file in "${RELEASE_GIT_FILES[@]}"; do
    if [[ -e "$ROOT/$file" ]]; then
      if ! git diff --quiet -- "$file" 2>/dev/null \
          || ! git diff --cached --quiet -- "$file" 2>/dev/null; then
        return 0
      fi
    fi
  done
  return 1
}

commit_release_metadata() {
  local version="$1"
  local file

  if ! release_metadata_changed; then
    return 0
  fi

  step "Committing release metadata"
  for file in "${RELEASE_GIT_FILES[@]}"; do
    if [[ -e "$ROOT/$file" ]]; then
      git add "$file"
    fi
  done
  git commit -m "Release $version"
  RELEASE_GIT_COMMITTED=true
}

create_local_release_tag() {
  local version="$1"
  local tag="v$version"

  if git rev-parse "$tag" >/dev/null 2>&1; then
    warn_msg "Локальный тег $tag уже существует — пропускаю создание"
    return 0
  fi

  git tag -a "$tag" -m "Release $version"
  RELEASE_GIT_TAGGED=true
}

rollback_release() {
  local exit_code=$?
  [[ $exit_code -eq 0 ]] && return 0
  [[ "$RELEASE_IN_PROGRESS" != true ]] && return "$exit_code"
  [[ "$RELEASE_SUCCEEDED" == true ]] && return "$exit_code"

  echo
  warn_msg "Публикация не удалась — откатываю изменения..."

  if [[ "$RELEASE_GH_PUBLISHED" == true ]]; then
    warn_msg "Релиз на GitHub уже создан — assets на GitHub не удаляются."
    if [[ "$RELEASE_GIT_PUSHED" != true ]]; then
      hint "Завершите вручную: git push origin HEAD"
    fi
    return "$exit_code"
  fi

  if [[ -n "$RELEASE_TAG" ]] && gh release view "$RELEASE_TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    gh release delete "$RELEASE_TAG" --repo "$RELEASE_REPO" --yes 2>/dev/null || true
    info "Удалён релиз $RELEASE_TAG на GitHub"
  fi

  if [[ -n "$PREVIOUS_VERSION" && "${VERSION:-}" != "$PREVIOUS_VERSION" ]]; then
    "$LIB_DIR/version.sh" set "$PREVIOUS_VERSION" >/dev/null
    info "Версия в Info.plist возвращена к $PREVIOUS_VERSION"
  fi

  if [[ "$RELEASE_GIT_PUSHED" == true ]]; then
    if git revert --no-edit HEAD >/dev/null 2>&1; then
      git push origin HEAD >/dev/null 2>&1 || \
        warn_msg "Не удалось отправить revert в origin — откатите git вручную"
      info "Отменён коммит Release ${VERSION:-?} в git"
    else
      warn_msg "Не удалось автоматически откатить git-коммит — проверьте репозиторий вручную"
    fi
  elif [[ "$RELEASE_GIT_COMMITTED" == true ]]; then
    git reset --hard HEAD~1 >/dev/null 2>&1 || true
    info "Локальный коммит Release ${VERSION:-?} удалён"
  fi

  if [[ "$RELEASE_GIT_TAG_PUSHED" == true ]]; then
    git push origin ":refs/tags/$RELEASE_TAG" >/dev/null 2>&1 || \
      warn_msg "Не удалось удалить тег $RELEASE_TAG на origin — удалите вручную"
    info "Удалён тег $RELEASE_TAG на origin"
  elif [[ "$RELEASE_GIT_TAGGED" == true ]]; then
    git tag -d "$RELEASE_TAG" >/dev/null 2>&1 || true
    info "Удалён локальный тег $RELEASE_TAG"
  fi

  return "$exit_code"
}

ensure_changelog_dependencies() {
  if [[ -f "$CHANGELOG_DIR/node_modules/@cursor/sdk/package.json" ]]; then
    return 0
  fi

  if ! command -v node >/dev/null 2>&1; then
    error_msg "Node.js is required for changelog generation (https://nodejs.org)."
    exit 1
  fi
  if ! command -v npm >/dev/null 2>&1; then
    error_msg "npm is required for changelog generation."
    exit 1
  fi

  step "Installing changelog dependencies (@cursor/sdk)"
  npm install --prefix "$CHANGELOG_DIR" --no-fund --no-audit
}

run_changelog() {
  node "$CHANGELOG_DIR/generate_changelog.mjs" "$@"
}

generate_release_changelog() {
  local version="$1"
  local section_file="$ROOT/dist/changelog-section-$version.ru.md"
  local section_file_en="$ROOT/dist/changelog-section-$version.en.md"
  local section_file_mono="$ROOT/dist/changelog-section-$version.md"
  local channel="stable"
  local release_date
  release_date="$(date +%Y-%m-%d)"

  rm -f "$section_file" "$section_file_en" "$section_file_mono"
  mkdir -p "$ROOT/dist"

  if [[ "$BETA" == true ]]; then
    channel="beta"
  fi

  if [[ "$CHANGELOG_BILINGUAL" == 1 ]]; then
    if run_changelog \
        --extract-existing \
        --version "$version" \
        --output "$section_file" \
        --output-en "$section_file_en" >/dev/null 2>&1; then
      info "Changelog для $version уже есть в CHANGELOG.md и CHANGELOG.en.md"
      GENERATED_CHANGELOG="$section_file"
      GENERATED_CHANGELOG_EN="$section_file_en"
      return 0
    fi
  elif run_changelog \
      --extract-existing \
      --version "$version" \
      --output "$section_file_mono" >/dev/null 2>&1; then
    info "Changelog для $version уже есть в CHANGELOG.md"
    GENERATED_CHANGELOG="$section_file_mono"
    return 0
  fi

  if [[ -z "${CURSOR_API_KEY:-}" ]]; then
    warn_msg "CURSOR_API_KEY не задан (export или .env) — используем fallback-changelog из git log"
    if [[ "$CHANGELOG_BILINGUAL" == 1 ]]; then
      run_changelog \
        --version "$version" \
        --channel "$channel" \
        --date "$release_date" \
        --fallback \
        --output "$section_file" \
        --output-en "$section_file_en"
      GENERATED_CHANGELOG="$section_file"
      GENERATED_CHANGELOG_EN="$section_file_en"
    else
      run_changelog \
        --version "$version" \
        --channel "$channel" \
        --date "$release_date" \
        --fallback \
        --output "$section_file_mono"
      GENERATED_CHANGELOG="$section_file_mono"
    fi
    return 0
  fi

  ensure_changelog_dependencies

  step "Генерация changelog через Cursor SDK"
  if [[ "$CHANGELOG_BILINGUAL" == 1 ]]; then
    step "(ru + en)"
    if ! run_changelog \
        --version "$version" \
        --channel "$channel" \
        --date "$release_date" \
        --output "$section_file" \
        --output-en "$section_file_en"; then
      warn_msg "Cursor SDK не смог сгенерировать changelog — используем fallback"
      run_changelog \
        --version "$version" \
        --channel "$channel" \
        --date "$release_date" \
        --fallback \
        --output "$section_file" \
        --output-en "$section_file_en"
    fi
    GENERATED_CHANGELOG="$section_file"
    GENERATED_CHANGELOG_EN="$section_file_en"
  else
    if ! run_changelog \
        --version "$version" \
        --channel "$channel" \
        --date "$release_date" \
        --output "$section_file_mono"; then
      warn_msg "Cursor SDK не смог сгенерировать changelog — используем fallback"
      run_changelog \
        --version "$version" \
        --channel "$channel" \
        --date "$release_date" \
        --fallback \
        --output "$section_file_mono"
    fi
    GENERATED_CHANGELOG="$section_file_mono"
  fi
}

preview_and_confirm_changelog() {
  local version="$1"

  if [[ -z "$GENERATED_CHANGELOG" || ! -f "$GENERATED_CHANGELOG" ]]; then
    return 0
  fi

  echo
  divider
  info "Предпросмотр changelog для версии $version (ru):"
  echo
  cat "$GENERATED_CHANGELOG"
  if [[ -n "$GENERATED_CHANGELOG_EN" && -f "$GENERATED_CHANGELOG_EN" ]]; then
    echo
    divider
    info "English:"
    echo
    cat "$GENERATED_CHANGELOG_EN"
  fi
  echo
  divider
  echo

  if [[ -t 0 && -t 1 ]]; then
    if ! read_yes_no "Использовать этот changelog? [Y/n]:" "y"; then
      warn_msg "Changelog не принят — будет использован минимальный текст релиза."
      GENERATED_CHANGELOG=""
      GENERATED_CHANGELOG_EN=""
      return 1
    fi
  fi

  return 0
}

apply_release_changelog() {
  local version="$1"

  if [[ -z "$GENERATED_CHANGELOG" || ! -f "$GENERATED_CHANGELOG" ]]; then
    RELEASE_NOTES="$RELEASE_APP_NAME $version"
    if [[ "$BETA" == true ]]; then
      RELEASE_NOTES="$RELEASE_APP_NAME $version — beta release for testers."
    fi
    return 0
  fi

  if [[ "$CHANGELOG_BILINGUAL" == 1 ]]; then
    if [[ -z "$GENERATED_CHANGELOG_EN" || ! -f "$GENERATED_CHANGELOG_EN" ]]; then
      RELEASE_NOTES="$RELEASE_APP_NAME $version"
      return 0
    fi

    python3 - "$version" "$GENERATED_CHANGELOG" "$GENERATED_CHANGELOG_EN" "$ROOT/CHANGELOG.md" "$ROOT/$CHANGELOG_EN" <<'PY'
import sys
from pathlib import Path
import re

version = sys.argv[1]
section_ru = Path(sys.argv[2]).read_text(encoding="utf-8").strip()
section_en = Path(sys.argv[3]).read_text(encoding="utf-8").strip()
paths = [Path(sys.argv[4]), Path(sys.argv[5])]
sections = [section_ru, section_en]
pattern = rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\s*$"

for changelog, section in zip(paths, sections):
    body = changelog.read_text(encoding="utf-8") if changelog.exists() else "# Changelog\n"
    if re.search(pattern, body, re.MULTILINE):
        continue
    marker = "\n## ["
    insert_at = body.find(marker)
    if insert_at == -1:
        updated = body.rstrip() + "\n\n" + section + "\n"
    else:
        updated = body[:insert_at].rstrip() + "\n\n" + section + "\n" + body[insert_at:]
    changelog.write_text(updated, encoding="utf-8")
PY

    RELEASE_NOTES="$(cat "$GENERATED_CHANGELOG_EN")"
    return 0
  fi

  python3 - "$version" "$GENERATED_CHANGELOG" "$ROOT/CHANGELOG.md" <<'PY'
import sys
from pathlib import Path
import re

version = sys.argv[1]
section = Path(sys.argv[2]).read_text(encoding="utf-8").strip()
changelog = Path(sys.argv[3])
pattern = rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\s*$"
body = changelog.read_text(encoding="utf-8") if changelog.exists() else "# Changelog\n"
if not re.search(pattern, body, re.MULTILINE):
    marker = "\n## ["
    insert_at = body.find(marker)
    if insert_at == -1:
        updated = body.rstrip() + "\n\n" + section + "\n"
    else:
        updated = body[:insert_at].rstrip() + "\n\n" + section + "\n" + body[insert_at:]
    changelog.write_text(updated, encoding="utf-8")
PY

  RELEASE_NOTES="$(cat "$GENERATED_CHANGELOG")"
}

prepare_release_changelog() {
  local version="$1"

  if [[ "$SKIP_CHANGELOG" == true ]]; then
    RELEASE_NOTES="$RELEASE_APP_NAME $version"
    if [[ "$BETA" == true ]]; then
      RELEASE_NOTES="$RELEASE_APP_NAME $version — beta release for testers."
    fi
    return 0
  fi

  step "Changelog"
  echo
  generate_release_changelog "$version"
  preview_and_confirm_changelog "$version" || true
  apply_release_changelog "$version"
}

create_github_release() {
  local tag="$1"
  local title="$2"
  local notes="$3"

  if [[ "$BETA" == true ]]; then
    gh release create "$tag" "$ARCHIVE" "$CHECKSUM" "$DMG" \
      --repo "$RELEASE_REPO" \
      --title "$title" \
      --notes "$notes" \
      --prerelease
  else
    gh release create "$tag" "$ARCHIVE" "$CHECKSUM" "$DMG" \
      --repo "$RELEASE_REPO" \
      --title "$title" \
      --notes "$notes"
  fi
}

init_colors

usage() {
  cat <<EOF
Usage: $0 [patch|minor|major] [options]

Options:
  --set VERSION    Set an explicit version in Info.plist
  --no-bump        Do not change Info.plist
  --publish        Create GitHub release in $RELEASE_REPO (requires gh)
  --beta           Mark the GitHub release as a prerelease (beta channel)
  --skip-build     Only bump/set version and/or package an existing build
  --package-only   Only create the release zip (expects dist/$APP_NAME.app)
  --skip-changelog Skip automatic changelog generation
  --old            Force stable Xcode.app (default: Xcode-beta, then Xcode)
  -h, --help       Show this help

Without patch/minor/major, --set or --no-bump the script runs interactively:
  channel, version, publish, changelog and a confirmation step before building.

Examples:
  $0
  $0 --publish
  $0 patch
  $0 minor --publish
  $0 patch --publish --beta
  $0 --set 2.0
  $0 --no-bump --publish
EOF
}

ensure_release_repo_ready() {
  if gh repo view "$RELEASE_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null | grep -q .; then
    return 0
  fi

  step "Initializing empty release repository $RELEASE_REPO"
  local readme="# $RELEASE_APP_NAME — Releases

Binary releases for the $RELEASE_APP_NAME macOS app.

Download the latest release from https://github.com/$RELEASE_REPO/releases."

  gh api \
    --method PUT \
    "repos/$RELEASE_REPO/contents/README.md" \
    -f message="Initialize release repository" \
    -f content="$(printf '%s' "$readme" | base64)" \
    -f branch="main"
}

is_valid_version() {
  "$LIB_DIR/version.sh" check "$1" >/dev/null 2>&1
}

read_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer=""
  printf '%b%s%b ' "$COLOR_BOLD" "$prompt" "$COLOR_RESET"
  read -r answer
  answer="${answer:-$default}"
  if [[ "$default" =~ ^[Yy]$ ]]; then
    [[ ! "$answer" =~ ^[Nn]$ ]]
  else
    [[ "$answer" =~ ^[Yy]$ ]]
  fi
}

channel_label() {
  if [[ "$BETA" == true ]]; then
    echo "Бета"
  else
    echo "Стабильный"
  fi
}

suggested_release_version() {
  if [[ "$BETA" == true ]]; then
    "$LIB_DIR/version.sh" preview-beta
    return
  fi

  local current="${PREVIOUS_VERSION:-$("$LIB_DIR/version.sh" print)}"
  if [[ "$current" == *-beta.* ]]; then
    echo "${current%%-beta.*}"
  else
    "$LIB_DIR/version.sh" preview patch
  fi
}

default_version_hint() {
  local suggested="$1"
  if [[ "$BETA" == true ]]; then
    hint "По умолчанию для бета-канала: $suggested"
    hint "Enter — следующая бета-сборка; можно ввести вручную"
  else
    hint "По умолчанию для стабильного канала: $suggested"
    hint "Enter — +1 patch; можно ввести вручную"
  fi
}

clear_screen() {
  [[ "${INTERACTIVE:-false}" == true ]] && clear
}

confirm_release_plan() {
  local current_version="$1"
  local new_version="$2"

  step "Релиз $RELEASE_APP_NAME — шаг 5/5: подтверждение"
  echo
  divider
  if [[ "$BETA" == true ]]; then
    warn_msg "Подтверждение бета-релиза"
    echo
    info "Релиз будет опубликован как prerelease."
    info "Его увидят только пользователи с каналом «Бета»."
  else
    warn_msg "Подтверждение стабильного релиза"
    echo
    info "Релиз попадёт в основной канал обновлений."
    info "Его получат все пользователи с каналом «Стабильный»."
  fi
  echo
  label_value "Текущая версия" "$current_version"
  label_value "Новая версия" "$new_version"
  label_value "Тег GitHub" "v$new_version"
  printf '  %bКанал:%b  ' "$COLOR_DIM" "$COLOR_RESET"
  channel_colored
  echo
  if [[ "$PUBLISH" == true ]]; then
    label_value "Публикация" "да → $RELEASE_REPO"
  else
    label_value "Публикация" "нет (только сборка и zip)"
  fi
  if [[ "$SKIP_CHANGELOG" == true ]]; then
    label_value "Changelog" "нет"
  elif [[ -n "${CURSOR_API_KEY:-}" ]]; then
    label_value "Changelog" "да, через Cursor SDK"
  else
    label_value "Changelog" "да, fallback из git log (нет CURSOR_API_KEY)"
  fi
  divider
  echo

  read_yes_no "Продолжить? [y/N]:" "n"
}

prompt_interactive_release() {
  local current_version suggested_version new_version channel_choice publish_choice

  current_version="$("$LIB_DIR/version.sh" print)"
  if [[ -z "$current_version" ]]; then
    error_msg "Could not read current version from Info.plist"
    exit 1
  fi

  clear_screen
  step "Релиз $RELEASE_APP_NAME — шаг 1/5: канал"
  label_value "Текущая версия" "$current_version"
  echo

  if [[ "$BETA" == false ]]; then
    info "Канал обновления:"
    menu_item "1) Стабильный — для всех пользователей"
    menu_item "2) Бета — prerelease для тестировщиков"
    printf '%bВыберите канал [1]:%b ' "$COLOR_BOLD" "$COLOR_RESET"
    read -r channel_choice
    channel_choice="${channel_choice:-1}"
    case "$channel_choice" in
      1|"") BETA=false ;;
      2) BETA=true ;;
      *)
        error_msg "Неизвестный канал: $channel_choice"
        exit 1
        ;;
    esac
  else
    printf 'Канал: '
    channel_colored
    echo " (--beta)"
  fi

  clear_screen
  suggested_version="$(suggested_release_version)"
  step "Релиз $RELEASE_APP_NAME — шаг 2/5: версия"
  label_value "Текущая версия" "$current_version"
  printf '  %bКанал:%b          ' "$COLOR_DIM" "$COLOR_RESET"
  channel_colored
  echo
  label_value "Версия по умолчанию" "$suggested_version"
  echo
  default_version_hint "$suggested_version"
  hint "Формат: 1.2.6 или 1.3.0-beta.1"
  echo

  while true; do
    if [[ "$BETA" == true ]]; then
      printf '%bНовая бета-версия [Enter → %s]:%b ' "$COLOR_BOLD" "$suggested_version" "$COLOR_RESET"
    else
      printf '%bНовая версия, стабильный канал [Enter → %s]:%b ' "$COLOR_BOLD" "$suggested_version" "$COLOR_RESET"
    fi
    read -r new_version
    new_version="${new_version:-$suggested_version}"
    new_version="${new_version#v}"

    if is_valid_version "$new_version"; then
      break
    fi

    error_msg "Некорректный формат версии: $new_version"
    hint "Примеры: 1.2.6, 1.3.0, 1.3.0-beta.1"
    if [[ "$BETA" == true ]]; then
      hint "Повторите ввод (Enter — бета по умолчанию: $suggested_version):"
    else
      hint "Повторите ввод (Enter — стабильный канал, по умолчанию: $suggested_version):"
    fi
  done

  clear_screen
  step "Релиз $RELEASE_APP_NAME — шаг 3/5: публикация"
  label_value "Новая версия" "$new_version"
  printf '  %bКанал:%b        ' "$COLOR_DIM" "$COLOR_RESET"
  channel_colored
  echo
  echo

  if [[ "$PUBLISH" == false ]]; then
    if read_yes_no "Опубликовать на GitHub после сборки? [Y/n]:" "y"; then
      PUBLISH=true
    fi
  else
    success_msg "Публикация на GitHub: да (--publish)"
  fi

  clear_screen
  step "Релиз $RELEASE_APP_NAME — шаг 4/5: changelog"
  label_value "Новая версия" "$new_version"
  printf '  %bКанал:%b        ' "$COLOR_DIM" "$COLOR_RESET"
  channel_colored
  echo
  if [[ -n "${CURSOR_API_KEY:-}" ]]; then
    label_value "CURSOR_API_KEY" "задан"
  else
    label_value "CURSOR_API_KEY" "не задан (export или .env в swift_scripts)"
  fi
  echo

  if [[ "$SKIP_CHANGELOG" == true ]]; then
    success_msg "Changelog: нет (--skip-changelog)"
  elif [[ -n "${CURSOR_API_KEY:-}" ]]; then
    if read_yes_no "Генерировать changelog через Cursor SDK? [Y/n]:" "y"; then
      SKIP_CHANGELOG=false
    else
      SKIP_CHANGELOG=true
    fi
  else
    warn_msg "Без CURSOR_API_KEY доступен только fallback из git log"
    if read_yes_no "Сгенерировать changelog из git log? [Y/n]:" "y"; then
      SKIP_CHANGELOG=false
    else
      SKIP_CHANGELOG=true
    fi
  fi

  clear_screen
  if ! confirm_release_plan "$current_version" "$new_version"; then
    warn_msg "Отменено."
    exit 0
  fi

  SET_VERSION="$new_version"
  NO_BUMP=false
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    patch|minor|major)
      BUMP="$1"
      ;;
    --set)
      SET_VERSION="${2:-}"
      if [[ -z "$SET_VERSION" ]]; then
        error_msg "Missing value for --set"
        exit 1
      fi
      SET_VERSION="${SET_VERSION#v}"
      if ! is_valid_version "$SET_VERSION"; then
        "$LIB_DIR/version.sh" check "$SET_VERSION" >&2 || true
        exit 1
      fi
      shift
      ;;
    --no-bump)
      NO_BUMP=true
      ;;
    --publish)
      PUBLISH=true
      ;;
    --beta)
      BETA=true
      ;;
    --skip-build)
      SKIP_BUILD=true
      ;;
    --package-only)
      PACKAGE_ONLY=true
      SKIP_BUILD=true
      NO_BUMP=true
      ;;
    --skip-changelog)
      SKIP_CHANGELOG=true
      ;;
    --old)
      USE_STABLE_XCODE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error_msg "Unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$NO_BUMP" == false && -z "$BUMP" && -z "$SET_VERSION" && "$PACKAGE_ONLY" == false ]]; then
  INTERACTIVE=true
fi

if [[ "$INTERACTIVE" == true ]]; then
  prompt_interactive_release
fi

PREVIOUS_VERSION="$("$LIB_DIR/version.sh" print)"

if [[ "$NO_BUMP" == false ]]; then
  if [[ -n "$SET_VERSION" && -n "$BUMP" ]]; then
    error_msg "Use either --set or patch/minor/major, not both."
    exit 1
  fi
  if [[ -n "$SET_VERSION" ]]; then
    step "Setting version to $SET_VERSION"
    "$LIB_DIR/version.sh" set "$SET_VERSION" >/dev/null
  elif [[ -n "$BUMP" ]]; then
    step "Bumping $BUMP version"
    NEW_VERSION="$("$LIB_DIR/version.sh" bump "$BUMP")"
    label_value "New version" "$NEW_VERSION"
  else
    step "Bumping patch version"
    NEW_VERSION="$("$LIB_DIR/version.sh" bump patch)"
    label_value "New version" "$NEW_VERSION"
  fi
fi

VERSION="$("$LIB_DIR/version.sh" print)"
if [[ -z "$VERSION" ]]; then
  error_msg "Could not read version from Info.plist"
  exit 1
fi

prepare_release_changelog "$VERSION"
sync_changelog_artifacts

if [[ "$SKIP_BUILD" == false ]]; then
  step "Сборка приложения"
  echo
  SWIFT_SCRIPTS_USE_STABLE_XCODE=$USE_STABLE_XCODE
  export SWIFT_SCRIPTS_USE_STABLE_XCODE
  "$LIB_DIR/build_app.sh"
fi

APP="$ROOT/dist/$APP_NAME.app"
ARCHIVE="$ROOT/dist/$APP_NAME-$VERSION.zip"
CHECKSUM="$ARCHIVE.sha256"

if [[ ! -d "$APP" ]]; then
  error_msg "App bundle not found: $APP"
  hint "Run ./release.sh --no-bump to build and package."
  exit 1
fi

step "Упаковка релиза"
echo
step "Cleaning old release archives in dist/"
rm -f "$ROOT/dist/$APP_NAME-"*.zip "$ROOT/dist/$APP_NAME-"*.zip.sha256 "$ROOT/dist/$APP_NAME-"*.dmg
step "Packaging $ARCHIVE"
rm -f "$ARCHIVE"
(
  cd "$ROOT/dist"
  /usr/bin/zip -r -X "$APP_NAME-$VERSION.zip" "$APP_NAME.app" >/dev/null
)

step "Writing $CHECKSUM"
/usr/bin/shasum -a 256 "$ARCHIVE" | awk '{print $1}' > "$CHECKSUM"

DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
step "Creating $DMG"
"$LIB_DIR/create_dmg.sh" "$APP" "$DMG"

echo
label_value "Release artifact" "$ARCHIVE"
label_value "Checksum" "$CHECKSUM"
label_value "Release DMG" "$DMG"
printf '  %bUpdate channel:%b  ' "$COLOR_DIM" "$COLOR_RESET"
channel_colored
echo

if [[ "$PUBLISH" == true ]]; then
  step "Публикация на GitHub"
  echo
  if ! command -v gh >/dev/null 2>&1; then
    error_msg "GitHub CLI (gh) is required for --publish."
    exit 1
  fi

  RELEASE_IN_PROGRESS=true
  trap rollback_release EXIT

  TAG="v$VERSION"
  RELEASE_TAG="$TAG"
  RELEASE_TITLE="$VERSION"
  if [[ "$BETA" == true ]]; then
    RELEASE_TITLE="$VERSION (beta)"
  fi

  ensure_release_repo_ready

  # Commit + tag + push first. gh release create would otherwise create the
  # remote tag itself, and a later `git push origin $TAG` fails with "already exists".
  commit_release_metadata "$VERSION"
  create_local_release_tag "$VERSION"

  step "Pushing version commit and tag to origin"
  git push origin HEAD
  RELEASE_GIT_PUSHED=true
  if [[ "$RELEASE_GIT_TAGGED" == true ]]; then
    git push origin "$TAG"
    RELEASE_GIT_TAG_PUSHED=true
  elif git rev-parse "$TAG" >/dev/null 2>&1; then
    # Tag already existed locally (e.g. retry) — ensure remote has it.
    if ! git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
      git push origin "$TAG"
      RELEASE_GIT_TAG_PUSHED=true
    fi
  fi

  if gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    step "Uploading assets to existing release $TAG in $RELEASE_REPO"
    gh release upload "$TAG" "$ARCHIVE" "$CHECKSUM" "$DMG" --repo "$RELEASE_REPO" --clobber
  else
    step "Creating GitHub release $TAG in $RELEASE_REPO"
    create_github_release "$TAG" "$RELEASE_TITLE" "$RELEASE_NOTES"
  fi
  RELEASE_GH_PUBLISHED=true

  RELEASE_SUCCEEDED=true
  trap - EXIT

  echo
  if [[ "$BETA" == true ]]; then
    success_msg "Published beta: https://github.com/$RELEASE_REPO/releases/tag/$TAG"
  else
    success_msg "Published: https://github.com/$RELEASE_REPO/releases/tag/$TAG"
  fi
  if [[ "$RELEASE_GIT_TAGGED" == true || "$RELEASE_GIT_TAG_PUSHED" == true ]]; then
    success_msg "Tagged this repo: $TAG"
  fi
else
  echo
  warn_msg "Next steps:"
  hint "  git add ${RELEASE_GIT_FILES[*]}"
  hint "  git commit -m \"Release $VERSION\""
  hint "  git tag -a v$VERSION -m \"Release $VERSION\""
  hint "  git push && git push origin v$VERSION"
  hint "  $0 --no-bump --publish$([[ "$BETA" == true ]] && echo " --beta")"
fi
