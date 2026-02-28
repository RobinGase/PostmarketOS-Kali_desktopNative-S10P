#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRECHECK="$ROOT_DIR/scripts/run_preflight.sh"

ENV_FILE=""

usage() {
  cat <<'EOU'
Usage:
  run_preflight_live.sh --env-file profiles/live_s10_exynos.env
EOU
}

fail_usage() {
  printf 'USAGE: %s\n' "$1" >&2
  usage >&2
  exit 2
}

safe_set_kv() {
  key="$1"
  value="$2"

  case "$key" in
    TARGET_MODEL|TARGET_CODENAME|TARGET_SOC|TARGET_SERIAL|MANIFEST|APPROVAL_ID|SIMULATE|PRECHECK_ADB_BIN)
      ;;
    *)
      fail_usage "unsupported key in env file: $key"
      ;;
  esac

  case "$key" in
    TARGET_MODEL) TARGET_MODEL="$value" ;;
    TARGET_CODENAME) TARGET_CODENAME="$value" ;;
    TARGET_SOC) TARGET_SOC="$value" ;;
    TARGET_SERIAL) TARGET_SERIAL="$value" ;;
    MANIFEST) MANIFEST="$value" ;;
    APPROVAL_ID) APPROVAL_ID="$value" ;;
    SIMULATE) SIMULATE="$value" ;;
    PRECHECK_ADB_BIN) PRECHECK_ADB_BIN="$value" ;;
  esac
}

parse_env_file() {
  env_path="$1"
  line_no=0

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))

    trimmed="$line"
    while [ "${trimmed# }" != "$trimmed" ]; do
      trimmed="${trimmed# }"
    done

    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      \#*) continue ;;
    esac

    case "$trimmed" in
      *=*) ;;
      *) fail_usage "invalid env line $line_no: missing '='" ;;
    esac

    key="${trimmed%%=*}"
    value="${trimmed#*=}"

    case "$key" in
      ''|*[!A-Za-z0-9_]*) fail_usage "invalid key at line $line_no: $key" ;;
    esac
    case "$key" in
      [0-9]*) fail_usage "invalid key at line $line_no: $key" ;;
    esac

    case "$value" in
      *'$('*|*'`'*) fail_usage "unsafe value at line $line_no for key $key" ;;
    esac

    if [ "${value#\"}" != "$value" ] && [ "${value%\"}" != "$value" ]; then
      value="${value#\"}"
      value="${value%\"}"
    elif [ "${value#\'}" != "$value" ] && [ "${value%\'}" != "$value" ]; then
      value="${value#\'}"
      value="${value%\'}"
    fi

    safe_set_kv "$key" "$value"
  done < "$env_path"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file)
      [ "$#" -ge 2 ] || fail_usage 'missing value for --env-file'
      ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail_usage "unknown argument: $1"
      ;;
  esac
done

[ -n "$ENV_FILE" ] || fail_usage '--env-file is required'
[ -f "$ENV_FILE" ] || fail_usage "env file not found: $ENV_FILE"

TARGET_MODEL=''
TARGET_CODENAME=''
TARGET_SOC=''
TARGET_SERIAL=''
MANIFEST=''
APPROVAL_ID=''
SIMULATE='off'
PRECHECK_ADB_BIN=''

parse_env_file "$ENV_FILE"

[ -n "$TARGET_MODEL" ] || fail_usage 'TARGET_MODEL is required in env file'
[ -n "$TARGET_CODENAME" ] || fail_usage 'TARGET_CODENAME is required in env file'
[ -n "$TARGET_SOC" ] || fail_usage 'TARGET_SOC is required in env file'
[ -n "$MANIFEST" ] || fail_usage 'MANIFEST is required in env file'
[ -n "$APPROVAL_ID" ] || fail_usage 'APPROVAL_ID is required in env file'

case "$SIMULATE" in
  off|strict) ;;
  *) fail_usage 'SIMULATE must be off or strict' ;;
esac

args=(
  --target-model "$TARGET_MODEL"
  --target-codename "$TARGET_CODENAME"
  --target-soc "$TARGET_SOC"
  --manifest "$MANIFEST"
  --approval-id "$APPROVAL_ID"
  --simulate "$SIMULATE"
)

if [ -n "$TARGET_SERIAL" ]; then
  args+=(--target-serial "$TARGET_SERIAL")
fi

if [ -n "$PRECHECK_ADB_BIN" ]; then
  PRECHECK_ADB_BIN="$PRECHECK_ADB_BIN" "$PRECHECK" "${args[@]}"
else
  "$PRECHECK" "${args[@]}"
fi
