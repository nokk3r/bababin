#!/usr/bin/env bash
# Load KEY=VALUE pairs from a .env file without overriding existing exports.
#
# Secrets like CURSOR_API_KEY live in SCRIPTS_DIR/.env. We also load ROOT/.env
# for optional per-app overrides (existing exports win).

load_env_file() {
  local env_file="$1"

  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" != *=* ]]; then
      continue
    fi

    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"

    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      continue
    fi

    if [[ -n "${!key:-}" ]]; then
      continue
    fi

    if [[ "$value" =~ ^\".*\"$ ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    fi

    export "$key=$value"
  done < "$env_file"
}

load_local_env() {
  if [[ $# -gt 0 ]]; then
    load_env_file "$1"
    return 0
  fi

  if [[ -n "${SCRIPTS_DIR:-}" ]]; then
    load_env_file "$SCRIPTS_DIR/.env"
  fi
  if [[ -n "${ROOT:-}" && "${ROOT:-}" != "${SCRIPTS_DIR:-}" ]]; then
    load_env_file "$ROOT/.env"
  elif [[ -z "${SCRIPTS_DIR:-}" ]]; then
    load_env_file "${ROOT:-.}/.env"
  fi
}
