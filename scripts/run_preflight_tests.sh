#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRECHECK="$ROOT_DIR/scripts/run_preflight.sh"
TEST_ARTIFACT_DIR="${PRECHECK_ARTIFACT_DIR:-$ROOT_DIR/artifacts}"

cd "$ROOT_DIR" || exit 1

pass_count=0
fail_count=0

assert_exit() {
  name="$1"
  expected="$2"
  shift 2

  set +e
  "$@"
  rc=$?
  set -e

  if [ "$rc" -eq "$expected" ]; then
    printf 'PASS: %s (rc=%s)\n' "$name" "$rc"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (expected=%s got=%s)\n' "$name" "$expected" "$rc"
    fail_count=$((fail_count + 1))
  fi
}

assert_exit_contains() {
  name="$1"
  expected_rc="$2"
  expected_text="$3"
  shift 3

  out_file="$tmp_dir/out_$(printf '%s' "$name" | tr -cd '[:alnum:]_-').log"
  set +e
  "$@" >"$out_file" 2>&1
  rc=$?
  set -e

  if [ "$rc" -eq "$expected_rc" ] && grep -Fq "$expected_text" "$out_file"; then
    printf 'PASS: %s (rc=%s contains=%s)\n' "$name" "$rc" "$expected_text"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (expected rc=%s contains=%s, got rc=%s)\n' "$name" "$expected_rc" "$expected_text" "$rc"
    fail_count=$((fail_count + 1))
  fi
}

assert_file_exists() {
  name="$1"
  path="$2"
  if [ -n "$path" ] && [ -f "$path" ]; then
    printf 'PASS: %s (file=%s)\n' "$name" "$path"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (missing file)\n' "$name"
    fail_count=$((fail_count + 1))
  fi
}

assert_json_contains() {
  name="$1"
  path="$2"
  expected_text="$3"
  if [ -n "$path" ] && [ -f "$path" ] && grep -Fq "$expected_text" "$path"; then
    printf 'PASS: %s (json contains=%s)\n' "$name" "$expected_text"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (json missing=%s)\n' "$name" "$expected_text"
    fail_count=$((fail_count + 1))
  fi
}

latest_json_for_approval() {
  approval="$1"
  ls -1t "$TEST_ARTIFACT_DIR"/preflight_*_"$approval".json 2>/dev/null | sed -n '1p' || true
}

latest_json_any() {
  ls -1t "$TEST_ARTIFACT_DIR"/preflight_*.json 2>/dev/null | sed -n '1p' || true
}

mk_manifest() {
  manifest_path="$1"
  payload_rel="$2"
  payload_path="$3"
  meta_model="$4"
  meta_codename="$5"
  meta_soc="$6"

  payload_hash="$(sha256sum "$payload_path" | cut -d' ' -f1)"
  {
    [ -n "$meta_model" ] && printf '# target_model=%s\n' "$meta_model"
    [ -n "$meta_codename" ] && printf '# target_codename=%s\n' "$meta_codename"
    [ -n "$meta_soc" ] && printf '# target_soc=%s\n' "$meta_soc"
    printf '%s  %s\n' "$payload_hash" "$payload_rel"
  } > "$manifest_path"
}

mk_fake_adb() {
  adb_path="$1"
  cat > "$adb_path" <<'EOF'
#!/usr/bin/env bash
set -u

devices_mode="${FAKE_ADB_DEVICES_MODE:-single}"
serial="${FAKE_ADB_SERIAL:-FAKE123}"
serial2="${FAKE_ADB_SERIAL2:-FAKE456}"
state="${FAKE_ADB_GET_STATE:-device}"
model="${FAKE_ADB_MODEL:-SM-G975F}"
codename="${FAKE_ADB_DEVICE:-beyond2lte}"
hardware="${FAKE_ADB_HARDWARE:-exynos9820}"

if [ "$#" -eq 1 ] && [ "$1" = "devices" ]; then
  printf 'List of devices attached\n'
  case "$devices_mode" in
    single)
      printf '%s\tdevice\n' "$serial"
      ;;
    multiple)
      printf '%s\tdevice\n' "$serial"
      printf '%s\tdevice\n' "$serial2"
      ;;
    none)
      ;;
    *)
      exit 90
      ;;
  esac
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = "-s" ]; then
  sel="$2"
  shift 2
  if [ "$1" = "get-state" ]; then
    if [ "$sel" = "$serial" ] || [ "$sel" = "$serial2" ]; then
      printf '%s\n' "$state"
      exit 0
    fi
    exit 1
  fi

  if [ "$1" = "shell" ] && [ "$2" = "getprop" ] && [ "$#" -eq 3 ]; then
    case "$3" in
      ro.product.model) printf '%s\n' "$model" ;;
      ro.product.device) printf '%s\n' "$codename" ;;
      ro.hardware) printf '%s\n' "$hardware" ;;
      *) printf '\n' ;;
    esac
    exit 0
  fi
fi

exit 91
EOF
  chmod +x "$adb_path"
}

mkdir -p "$TEST_ARTIFACT_DIR"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

payload="$tmp_dir/payload.bin"
printf 'fixture-data\n' > "$payload"

manifest_good="$tmp_dir/manifest_good.txt"
mk_manifest "$manifest_good" "payload.bin" "$payload" "SM-G975F" "beyond2lte" "exynos"

manifest_malformed="$tmp_dir/manifest_malformed.txt"
printf '# target_model=SM-G975F\nnot-a-valid-line\n' > "$manifest_malformed"

manifest_bad_hash="$tmp_dir/manifest_bad_hash.txt"
{
  printf '# target_model=SM-G975F\n'
  printf '# target_codename=beyond2lte\n'
  printf '# target_soc=exynos\n'
  printf '0000000000000000000000000000000000000000000000000000000000000000  payload.bin\n'
} > "$manifest_bad_hash"

manifest_snapdragon="$tmp_dir/manifest_snapdragon.txt"
mk_manifest "$manifest_snapdragon" "payload.bin" "$payload" "SM-G975F" "beyond2lte" "snapdragon"

fake_adb="$tmp_dir/fake_adb.sh"
mk_fake_adb "$fake_adb"

assert_exit "happy strict pass" 0 \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_good" --approval-id "APR-001" --simulate strict

pass_json="$(latest_json_for_approval "APR-001")"
assert_file_exists "pass JSON artifact exists" "$pass_json"
assert_json_contains "pass JSON result field" "$pass_json" '"result": "PASS"'
assert_json_contains "pass JSON exit_code field" "$pass_json" '"exit_code": 0'
assert_json_contains "pass JSON schema version" "$pass_json" '"schema_version": "1.0"'
assert_json_contains "pass JSON tool version" "$pass_json" '"tool_version": "preflight-shell-1.0"'

assert_exit "missing approval denied" 4 \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_good" --simulate strict

assert_exit "invalid simulate usage denied" 2 \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_good" --approval-id "APR-USAGE-001" --simulate badmode

usage_json="$(latest_json_for_approval "APR-USAGE-001")"
assert_file_exists "usage JSON artifact exists" "$usage_json"
assert_json_contains "usage JSON stage field" "$usage_json" '"failure_stage": "usage"'
assert_json_contains "usage JSON exit code" "$usage_json" '"exit_code": 2'

isolated_dir="$tmp_dir/isolated_artifacts"
mkdir -p "$isolated_dir"
assert_exit "override artifact dir pass" 0 \
  env PRECHECK_ARTIFACT_DIR="$isolated_dir" \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_good" --approval-id "APR-OVERRIDE-001" --simulate strict

isolated_json="$(ls -1t "$isolated_dir"/preflight_*_APR-OVERRIDE-001.json 2>/dev/null | sed -n '1p' || true)"
assert_file_exists "override dir JSON exists" "$isolated_json"

assert_exit "malformed manifest denied" 3 \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_malformed" --approval-id "APR-002" --simulate strict

fail_json="$(latest_json_for_approval "APR-002")"
assert_file_exists "fail JSON artifact exists" "$fail_json"
assert_json_contains "fail JSON result field" "$fail_json" '"result": "FAIL"'
assert_json_contains "fail JSON exit_code field" "$fail_json" '"exit_code": 3'

assert_exit "hash mismatch denied" 3 \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_bad_hash" --approval-id "APR-003" --simulate strict

assert_exit "S10+ Exynos metadata pass" 0 \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_good" --approval-id "APR-004" --simulate strict

assert_exit "S10+ lane Snapdragon metadata denied" 3 \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_snapdragon" --approval-id "APR-005" --simulate strict

assert_exit "off mode happy pass" 0 \
  env PRECHECK_ADB_BIN="$fake_adb" FAKE_ADB_DEVICES_MODE="single" FAKE_ADB_GET_STATE="device" \
  FAKE_ADB_MODEL="SM-G975F" FAKE_ADB_DEVICE="beyond2lte" FAKE_ADB_HARDWARE="exynos9820" \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --target-serial "FAKE123" --manifest "$manifest_good" --approval-id "APR-006" --simulate off

assert_exit_contains "off mode missing adb denied" 4 "adb binary not executable" \
  env PRECHECK_ADB_BIN="$tmp_dir/does-not-exist/adb" \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_good" --approval-id "APR-007" --simulate off

assert_exit_contains "off mode multiple devices denied" 4 "expected exactly one connected device" \
  env PRECHECK_ADB_BIN="$fake_adb" FAKE_ADB_DEVICES_MODE="multiple" \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_good" --approval-id "APR-008" --simulate off

assert_exit_contains "off mode get-state denied" 4 "adb get-state must be device" \
  env PRECHECK_ADB_BIN="$fake_adb" FAKE_ADB_DEVICES_MODE="single" FAKE_ADB_GET_STATE="offline" \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_good" --approval-id "APR-009" --simulate off

assert_exit_contains "off mode identity mismatch denied" 4 "device codename mismatch" \
  env PRECHECK_ADB_BIN="$fake_adb" FAKE_ADB_DEVICES_MODE="single" FAKE_ADB_GET_STATE="device" \
  FAKE_ADB_DEVICE="wrongcodename" \
  "$PRECHECK" --target-model "SM-G975F" --target-codename "beyond2lte" --target-soc "exynos" \
  --manifest "$manifest_good" --approval-id "APR-010" --simulate off

printf 'RESULT: pass=%s fail=%s\n' "$pass_count" "$fail_count"

[ "$fail_count" -eq 0 ]
