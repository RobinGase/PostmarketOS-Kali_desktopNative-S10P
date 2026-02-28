#!/usr/bin/env bash

set -euo pipefail

EXIT_USAGE=2
EXIT_SAFETY=3
EXIT_READINESS=4
EXIT_ARTIFACT=5

SCHEMA_VERSION="1.0"
TOOL_VERSION="preflight-shell-1.0"

TARGET_MODEL=""
TARGET_CODENAME=""
TARGET_SOC=""
TARGET_SERIAL=""
MANIFEST=""
APPROVAL_ID=""
SIMULATE="strict"

ARTIFACT_DIR="${PRECHECK_ARTIFACT_DIR:-artifacts}"
ts=""
log_path=""
evidence_path=""

manifest_entry_count=0
meta_model=""
meta_codename=""
meta_soc=""
selected_serial=""

evidence_emitted=0
in_failure_path=0

usage() {
  cat <<'EOU'
Usage:
  run_preflight.sh --target-model MODEL --target-codename CODENAME --target-soc SOC \
    --manifest PATH --approval-id ID [--target-serial SERIAL] [--simulate strict|off]
EOU
}

json_escape() {
  s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

emit_evidence() {
  result="$1"
  exit_code="$2"
  failure_stage="$3"
  failure_reason="$4"

  [ -n "$evidence_path" ] || return 0

  if [ -z "$ts" ]; then
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
  fi

  case "$manifest_entry_count" in
    ''|*[!0-9]*) manifest_entry_count=0 ;;
  esac

  tmp_path="$evidence_path.tmp.$$"
  {
    printf '{\n'
    printf '  "schema_version": "%s",\n' "$(json_escape "$SCHEMA_VERSION")"
    printf '  "tool_version": "%s",\n' "$(json_escape "$TOOL_VERSION")"
    printf '  "timestamp": "%s",\n' "$(json_escape "$ts")"
    printf '  "approval_id": "%s",\n' "$(json_escape "$APPROVAL_ID")"
    printf '  "simulate": "%s",\n' "$(json_escape "$SIMULATE")"
    printf '  "target_model": "%s",\n' "$(json_escape "$TARGET_MODEL")"
    printf '  "target_codename": "%s",\n' "$(json_escape "$TARGET_CODENAME")"
    printf '  "target_soc": "%s",\n' "$(json_escape "$TARGET_SOC")"
    printf '  "target_serial_requested": "%s",\n' "$(json_escape "$TARGET_SERIAL")"
    printf '  "selected_serial": "%s",\n' "$(json_escape "$selected_serial")"
    printf '  "manifest_path": "%s",\n' "$(json_escape "$MANIFEST")"
    printf '  "manifest_entry_count": %s,\n' "$manifest_entry_count"
    printf '  "manifest_metadata": {\n'
    printf '    "model": "%s",\n' "$(json_escape "$meta_model")"
    printf '    "codename": "%s",\n' "$(json_escape "$meta_codename")"
    printf '    "soc": "%s"\n' "$(json_escape "$meta_soc")"
    printf '  },\n'
    printf '  "result": "%s",\n' "$(json_escape "$result")"
    printf '  "exit_code": %s,\n' "$exit_code"
    printf '  "failure_stage": "%s",\n' "$(json_escape "$failure_stage")"
    printf '  "failure_reason": "%s",\n' "$(json_escape "$failure_reason")"
    printf '  "log_path": "%s"\n' "$(json_escape "$log_path")"
    printf '}\n'
  } > "$tmp_path" 2>/dev/null || return 0

  mv "$tmp_path" "$evidence_path" 2>/dev/null || return 0
  evidence_emitted=1
}

log() {
  if [ -n "$log_path" ]; then
    printf '%s\n' "$1" | tee -a "$log_path"
  else
    printf '%s\n' "$1"
  fi
}

prepare_artifact_context() {
  if [ -z "$ts" ]; then
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
  fi

  mkdir -p "$ARTIFACT_DIR" 2>/dev/null || true

  if [ -z "$log_path" ] || [ -z "$evidence_path" ]; then
    safe_model="$(printf '%s' "${TARGET_MODEL:-unknown}" | tr -cd '[:alnum:]_-')"
    [ -n "$safe_model" ] || safe_model='unknown'
    safe_approval="$(printf '%s' "${APPROVAL_ID:-usage}" | tr -cd '[:alnum:]_-')"
    [ -n "$safe_approval" ] || safe_approval='usage'
    log_path="$ARTIFACT_DIR/preflight_${ts}_${safe_model}_${SIMULATE}_${safe_approval}.log"
    evidence_path="$ARTIFACT_DIR/preflight_${ts}_${safe_model}_${SIMULATE}_${safe_approval}.json"
  fi

  if [ ! -f "$log_path" ]; then
    touch "$log_path" 2>/dev/null || true
  fi
}

handle_unexpected_error() {
  rc="$1"
  line_no="$2"

  if [ "$in_failure_path" -eq 1 ] || [ "$evidence_emitted" -eq 1 ]; then
    return
  fi

  in_failure_path=1
  prepare_artifact_context
  reason="unexpected command failure rc=$rc line=$line_no"
  log "preflight_result=FAIL stage=artifact reason=$reason"
  emit_evidence "FAIL" "$EXIT_ARTIFACT" "artifact" "$reason"
  printf 'ARTIFACT ERROR: %s\n' "$reason" >&2
  exit "$EXIT_ARTIFACT"
}

fail_usage() {
  in_failure_path=1
  prepare_artifact_context
  log "preflight_result=FAIL stage=usage reason=$1"
  emit_evidence "FAIL" "$EXIT_USAGE" "usage" "$1"
  printf 'USAGE: %s\n' "$1" >&2
  usage >&2
  exit "$EXIT_USAGE"
}

fail_safety() {
  in_failure_path=1
  reason="$1"
  log "preflight_result=FAIL stage=safety reason=$reason"
  emit_evidence "FAIL" "$EXIT_SAFETY" "safety" "$reason"
  printf 'SAFETY DENY: %s\n' "$reason" >&2
  exit "$EXIT_SAFETY"
}

fail_readiness() {
  in_failure_path=1
  reason="$1"
  log "preflight_result=FAIL stage=readiness reason=$reason"
  emit_evidence "FAIL" "$EXIT_READINESS" "readiness" "$reason"
  printf 'READINESS DENY: %s\n' "$reason" >&2
  exit "$EXIT_READINESS"
}

fail_artifact() {
  in_failure_path=1
  reason="$1"
  log "preflight_result=FAIL stage=artifact reason=$reason"
  emit_evidence "FAIL" "$EXIT_ARTIFACT" "artifact" "$reason"
  printf 'ARTIFACT ERROR: %s\n' "$reason" >&2
  exit "$EXIT_ARTIFACT"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

trap 'handle_unexpected_error "$?" "${LINENO}"' ERR

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-model)
      [ "$#" -ge 2 ] || fail_usage "missing value for --target-model"
      TARGET_MODEL="$2"
      shift 2
      ;;
    --target-codename)
      [ "$#" -ge 2 ] || fail_usage "missing value for --target-codename"
      TARGET_CODENAME="$2"
      shift 2
      ;;
    --target-soc)
      [ "$#" -ge 2 ] || fail_usage "missing value for --target-soc"
      TARGET_SOC="$2"
      shift 2
      ;;
    --target-serial)
      [ "$#" -ge 2 ] || fail_usage "missing value for --target-serial"
      TARGET_SERIAL="$2"
      shift 2
      ;;
    --manifest)
      [ "$#" -ge 2 ] || fail_usage "missing value for --manifest"
      MANIFEST="$2"
      shift 2
      ;;
    --approval-id)
      [ "$#" -ge 2 ] || fail_usage "missing value for --approval-id"
      APPROVAL_ID="$2"
      shift 2
      ;;
    --simulate)
      [ "$#" -ge 2 ] || fail_usage "missing value for --simulate"
      SIMULATE="$2"
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

[ -n "$TARGET_MODEL" ] || fail_usage "--target-model is required"
[ -n "$TARGET_CODENAME" ] || fail_usage "--target-codename is required"
[ -n "$TARGET_SOC" ] || fail_usage "--target-soc is required"
[ -n "$MANIFEST" ] || fail_usage "--manifest is required"

case "$SIMULATE" in
  strict|off) ;;
  *) fail_usage "--simulate must be strict or off" ;;
esac

prepare_artifact_context
[ -d "$ARTIFACT_DIR" ] || fail_artifact "missing artifact directory: $ARTIFACT_DIR"
[ -w "$ARTIFACT_DIR" ] || fail_artifact "artifact directory not writable: $ARTIFACT_DIR"

touch "$log_path" 2>/dev/null || fail_artifact "cannot write log file: $log_path"

log "preflight_start ts=$ts approval_id=${APPROVAL_ID:-<empty>} simulate=$SIMULATE"
log "target model=$TARGET_MODEL codename=$TARGET_CODENAME soc=$TARGET_SOC"
log "target serial=${TARGET_SERIAL:-auto}"
log "manifest path=$MANIFEST"

[ -n "$APPROVAL_ID" ] || fail_readiness "--approval-id is required"

[ -f "$MANIFEST" ] || fail_safety "manifest not found: $MANIFEST"

target_model_lc="$(lower "$TARGET_MODEL")"
target_codename_lc="$(lower "$TARGET_CODENAME")"
target_soc_lc="$(lower "$TARGET_SOC")"

is_s10_exynos_lane=0
if [ "$target_model_lc" = "sm-g975f" ] || [ "$target_codename_lc" = "beyond2lte" ] || [ "$target_soc_lc" = "exynos" ]; then
  is_s10_exynos_lane=1
fi

if printf '%s' "$target_soc_lc" | grep -Eq 'qcom|snapdragon'; then
  fail_safety "target SoC indicates Snapdragon/QCOM, denied in WS-J short-term lane"
fi

manifest_dir="$(dirname "$MANIFEST")"

while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue

  case "$line" in
    \#*)
      meta_line="${line#\#}"
      while [ "${meta_line# }" != "$meta_line" ]; do
        meta_line="${meta_line# }"
      done
      case "$meta_line" in
        target_model=*) meta_model="${meta_line#target_model=}" ;;
        target_codename=*) meta_codename="${meta_line#target_codename=}" ;;
        target_soc=*) meta_soc="${meta_line#target_soc=}" ;;
      esac
      continue
      ;;
  esac

  if [[ "$line" =~ ^([A-Fa-f0-9]{64})[[:space:]][[:space:]](.+)$ ]]; then
    expected_hash="${BASH_REMATCH[1]}"
    rel_file="${BASH_REMATCH[2]}"
    file_path="$manifest_dir/$rel_file"
    [ -f "$file_path" ] || fail_safety "manifest file missing: $rel_file"
    actual_hash="$(sha256sum "$file_path" | cut -d' ' -f1)"
    [ "$actual_hash" = "$expected_hash" ] || fail_safety "hash mismatch for $rel_file"
    manifest_entry_count=$((manifest_entry_count + 1))
  else
    fail_safety "malformed manifest line: $line"
  fi
done < "$MANIFEST"

[ "$manifest_entry_count" -gt 0 ] || fail_safety "manifest has no checksum entries"

if [ -n "$meta_model" ] && [ "$(lower "$meta_model")" != "$target_model_lc" ]; then
  fail_safety "manifest target_model mismatch: $meta_model"
fi

if [ -n "$meta_codename" ] && [ "$(lower "$meta_codename")" != "$target_codename_lc" ]; then
  fail_safety "manifest target_codename mismatch: $meta_codename"
fi

if [ -n "$meta_soc" ]; then
  meta_soc_lc="$(lower "$meta_soc")"
  if [ "$meta_soc_lc" != "$target_soc_lc" ]; then
    fail_safety "manifest target_soc mismatch: $meta_soc"
  fi
  if printf '%s' "$meta_soc_lc" | grep -Eq 'qcom|snapdragon'; then
    fail_safety "manifest target_soc indicates Snapdragon/QCOM"
  fi
fi

if [ "$is_s10_exynos_lane" -eq 1 ] && [ -n "$meta_soc" ]; then
  if printf '%s' "$(lower "$meta_soc")" | grep -Eq 'qcom|snapdragon'; then
    fail_safety "S10+ Exynos lane with Snapdragon/QCOM manifest metadata"
  fi
fi

if [ "$SIMULATE" = "strict" ]; then
  log "strict_mode enabled: skipping live device checks by design"
else
  adb_bin="${PRECHECK_ADB_BIN:-adb}"
  log "off_mode enabled: running read-only live checks"
  log "adb_bin=$adb_bin"

  if [[ "$adb_bin" == */* ]]; then
    [ -x "$adb_bin" ] || fail_readiness "adb binary not executable: $adb_bin"
  else
    command -v "$adb_bin" >/dev/null 2>&1 || fail_readiness "adb binary not found in PATH: $adb_bin"
  fi

  adb_devices_out="$($adb_bin devices 2>&1)"
  adb_devices_rc=$?
  [ "$adb_devices_rc" -eq 0 ] || fail_readiness "adb devices failed rc=$adb_devices_rc"

  device_rows=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "List of devices attached" ] && continue
    case "$line" in
      *$'\t'device)
        serial="${line%%$'\t'*}"
        [ -n "$serial" ] || continue
        device_rows+=("$serial")
        ;;
    esac
  done <<< "$adb_devices_out"

  device_count="${#device_rows[@]}"
  [ "$device_count" -eq 1 ] || fail_readiness "expected exactly one connected device, found $device_count"

  selected_serial="${device_rows[0]}"
  if [ -n "$TARGET_SERIAL" ]; then
    [ "$TARGET_SERIAL" = "$selected_serial" ] || fail_readiness "target serial not present: $TARGET_SERIAL"
  fi
  log "selected_serial=$selected_serial"

  state="$($adb_bin -s "$selected_serial" get-state 2>/dev/null || true)"
  [ "$state" = "device" ] || fail_readiness "adb get-state must be device, got ${state:-<empty>}"

  device_model="$($adb_bin -s "$selected_serial" shell getprop ro.product.model 2>/dev/null || true)"
  device_codename="$($adb_bin -s "$selected_serial" shell getprop ro.product.device 2>/dev/null || true)"
  device_hardware="$($adb_bin -s "$selected_serial" shell getprop ro.hardware 2>/dev/null || true)"

  [ -n "$device_model" ] || fail_readiness "empty device property: ro.product.model"
  [ -n "$device_codename" ] || fail_readiness "empty device property: ro.product.device"
  [ -n "$device_hardware" ] || fail_readiness "empty device property: ro.hardware"

  log "device ro.product.model=$device_model"
  log "device ro.product.device=$device_codename"
  log "device ro.hardware=$device_hardware"

  device_model_lc="$(lower "$device_model")"
  device_codename_lc="$(lower "$device_codename")"
  device_hardware_lc="$(lower "$device_hardware")"

  [ "$device_model_lc" = "$target_model_lc" ] || fail_readiness "device model mismatch: expected $TARGET_MODEL got $device_model"
  [ "$device_codename_lc" = "$target_codename_lc" ] || fail_readiness "device codename mismatch: expected $TARGET_CODENAME got $device_codename"

  case "$device_hardware_lc" in
    *"$target_soc_lc"*) ;;
    *) fail_readiness "device hardware mismatch for target soc: expected token $TARGET_SOC got $device_hardware" ;;
  esac

  if printf '%s' "$device_hardware_lc" | grep -Eq 'qcom|snapdragon'; then
    fail_safety "connected device indicates Snapdragon/QCOM hardware"
  fi

  if [ -n "$meta_model" ]; then
    [ "$device_model_lc" = "$(lower "$meta_model")" ] || fail_readiness "device model mismatch vs manifest metadata"
  fi
  if [ -n "$meta_codename" ]; then
    [ "$device_codename_lc" = "$(lower "$meta_codename")" ] || fail_readiness "device codename mismatch vs manifest metadata"
  fi
  if [ -n "$meta_soc" ]; then
    meta_soc_lc="$(lower "$meta_soc")"
    case "$device_hardware_lc" in
      *"$meta_soc_lc"*) ;;
      *) fail_readiness "device hardware mismatch vs manifest target_soc: $meta_soc" ;;
    esac
  fi
fi

log "preflight_result=PASS"
log "artifact_log=$log_path"
log "artifact_json=$evidence_path"
emit_evidence "PASS" 0 "" ""
exit 0
