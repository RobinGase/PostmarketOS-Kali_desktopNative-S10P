#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIVE_RUNNER="$ROOT_DIR/scripts/run_preflight_live.sh"
TEST_ARTIFACT_DIR="${PRECHECK_ARTIFACT_DIR:-$ROOT_DIR/artifacts}"

cd "$ROOT_DIR" || exit 1

pass_count=0
fail_count=0

tmp_root="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

assert_exit_contains() {
  name="$1"
  expected_rc="$2"
  expected_text="$3"
  shift 3

  out_file="$tmp_root/out_$(printf '%s' "$name" | tr -cd '[:alnum:]_-').log"
  set +e
  "$@" >"$out_file" 2>&1
  rc=$?
  set -e

  if [ "$rc" -eq "$expected_rc" ] && grep -Fq "$expected_text" "$out_file"; then
    printf 'PASS: %s (rc=%s contains=%s)\n' "$name" "$rc" "$expected_text"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (expected rc=%s contains=%s got=%s)\n' "$name" "$expected_rc" "$expected_text" "$rc"
    fail_count=$((fail_count + 1))
  fi
}

assert_exit() {
  name="$1"
  expected_rc="$2"
  shift 2

  set +e
  "$@"
  rc=$?
  set -e

  if [ "$rc" -eq "$expected_rc" ]; then
    printf 'PASS: %s (rc=%s)\n' "$name" "$rc"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (expected=%s got=%s)\n' "$name" "$expected_rc" "$rc"
    fail_count=$((fail_count + 1))
  fi
}

mk_manifest() {
  manifest_path="$1"
  payload_rel="$2"
  payload_path="$3"

  payload_hash="$(sha256sum "$payload_path" | cut -d' ' -f1)"
  {
    printf '# target_model=SM-G975F\n'
    printf '# target_codename=beyond2lte\n'
    printf '# target_soc=exynos\n'
    printf '%s  %s\n' "$payload_hash" "$payload_rel"
  } > "$manifest_path"
}

mk_fake_adb() {
  adb_path="$1"
  cat > "$adb_path" <<'ADBEOF'
#!/usr/bin/env bash
set -u

serial="${FAKE_ADB_SERIAL:-FAKE123}"
state="${FAKE_ADB_GET_STATE:-device}"
model="${FAKE_ADB_MODEL:-SM-G975F}"
codename="${FAKE_ADB_DEVICE:-beyond2lte}"
hardware="${FAKE_ADB_HARDWARE:-exynos9820}"

if [ "$#" -eq 1 ] && [ "$1" = 'devices' ]; then
  printf 'List of devices attached\n'
  printf '%s\tdevice\n' "$serial"
  exit 0
fi

if [ "$#" -ge 3 ] && [ "$1" = '-s' ]; then
  selected="$2"
  shift 2
  if [ "$selected" != "$serial" ]; then
    exit 1
  fi

  if [ "$1" = 'get-state' ]; then
    printf '%s\n' "$state"
    exit 0
  fi

  if [ "$1" = 'shell' ] && [ "$2" = 'getprop' ] && [ "$#" -eq 3 ]; then
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
ADBEOF
  chmod +x "$adb_path"
}

latest_json_for_approval() {
  approval="$1"
  ls -1t "$TEST_ARTIFACT_DIR"/preflight_*_"$approval".json 2>/dev/null | sed -n '1p' || true
}

assert_file_exists() {
  name="$1"
  path="$2"
  if [ -n "$path" ] && [ -f "$path" ]; then
    printf 'PASS: %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (missing=%s)\n' "$name" "$path"
    fail_count=$((fail_count + 1))
  fi
}

assert_json_contains() {
  name="$1"
  path="$2"
  expected_text="$3"
  if [ -n "$path" ] && [ -f "$path" ] && grep -Fq "$expected_text" "$path"; then
    printf 'PASS: %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (missing=%s)\n' "$name" "$expected_text"
    fail_count=$((fail_count + 1))
  fi
}

mkdir -p "$TEST_ARTIFACT_DIR"

payload="$tmp_root/payload.bin"
printf 'fixture-data\n' > "$payload"
manifest="$tmp_root/manifest_good.txt"
mk_manifest "$manifest" 'payload.bin' "$payload"

fake_adb="$tmp_root/fake_adb.sh"
mk_fake_adb "$fake_adb"

missing_field_env="$tmp_root/live_missing.env"
cat > "$missing_field_env" <<ENVEOF
TARGET_MODEL=SM-G975F
TARGET_CODENAME=beyond2lte
TARGET_SOC=exynos
MANIFEST=$manifest
TARGET_SERIAL=FAKE123
SIMULATE=off
PRECHECK_ADB_BIN=$fake_adb
ENVEOF

assert_exit_contains 'missing required field denied' 2 'APPROVAL_ID is required' "$LIVE_RUNNER" --env-file "$missing_field_env"

happy_env="$tmp_root/live_happy.env"
cat > "$happy_env" <<ENVEOF
TARGET_MODEL=SM-G975F
TARGET_CODENAME=beyond2lte
TARGET_SOC=exynos
TARGET_SERIAL=FAKE123
MANIFEST=$manifest
APPROVAL_ID=APR-LIVE-001
SIMULATE=off
PRECHECK_ADB_BIN=$fake_adb
ENVEOF

assert_exit 'happy off pass' 0 "$LIVE_RUNNER" --env-file "$happy_env"

live_json="$(latest_json_for_approval 'APR-LIVE-001')"
assert_file_exists 'live runner emitted evidence JSON' "$live_json"
assert_json_contains 'live evidence schema version' "$live_json" '"schema_version": "1.0"'
assert_json_contains 'live evidence tool version' "$live_json" '"tool_version": "preflight-shell-1.0"'

printf 'RESULT: pass=%s fail=%s\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
