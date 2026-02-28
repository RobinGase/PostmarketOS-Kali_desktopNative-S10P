#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$ROOT_DIR/artifacts"
RUN_ROOT="$ARTIFACT_DIR/runs"
SCHEMA_VERSION="1.0"
TOOL_VERSION="pipeline-shell-1.0"

mkdir -p "$ARTIFACT_DIR" "$RUN_ROOT"

LOCK_FILE="$ARTIFACT_DIR/.pipeline.lock"
LOCK_DIR="$ARTIFACT_DIR/.pipeline.lock.d"
LOCK_MODE=""

acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if flock -n 9; then
      LOCK_MODE='flock'
      return
    fi
    printf 'PIPELINE RESULT: FAIL (lock busy)\n' >&2
    exit 1
  fi

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_MODE='dir'
    return
  fi

  printf 'PIPELINE RESULT: FAIL (lock busy)\n' >&2
  exit 1
}

release_lock() {
  if [ "$LOCK_MODE" = 'dir' ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

trap release_lock EXIT
acquire_lock

utc_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="${utc_stamp}_${RANDOM}${RANDOM}"
RUN_DIR="$RUN_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"
pipeline_result='PASS'

declare -a syntax_targets=(
  'scripts/run_preflight.sh'
  'scripts/run_preflight_tests.sh'
  'scripts/prune_artifacts.sh'
  'scripts/prune_artifacts_tests.sh'
  'scripts/run_preflight_live.sh'
  'scripts/run_preflight_live_tests.sh'
  'scripts/run_pipeline.sh'
)

declare -a test_targets=(
  'scripts/prune_artifacts_tests.sh'
  'scripts/run_preflight_tests.sh'
  'scripts/run_preflight_live_tests.sh'
)

declare -a test_summaries=()

step=1
syntax_total="${#syntax_targets[@]}"
for rel in "${syntax_targets[@]}"; do
  abs="$ROOT_DIR/$rel"
  printf '[%s/%s] bash -n %s\n' "$step" "$syntax_total" "$rel"
  if ! bash -n "$abs"; then
    pipeline_result='FAIL'
    printf 'PIPELINE RESULT: FAIL (syntax)\n'
    exit 1
  fi
  step=$((step + 1))
done

test_idx=1
test_total="${#test_targets[@]}"
for rel in "${test_targets[@]}"; do
  abs="$ROOT_DIR/$rel"
  out_file="$RUN_DIR/pipeline_${utc_stamp}_$(basename "$rel" .sh).log"
  printf '[test %s/%s] bash %s\n' "$test_idx" "$test_total" "$rel"
  if ! PRECHECK_ARTIFACT_DIR="$RUN_DIR" bash "$abs" > "$out_file" 2>&1; then
    cat "$out_file"
    pipeline_result='FAIL'
    printf 'PIPELINE RESULT: FAIL (tests)\n'
    exit 1
  fi
  cat "$out_file"
  summary_line="$(grep -E 'RESULT: pass=[0-9]+ fail=[0-9]+' "$out_file" | tail -n 1 || true)"
  if [ -z "$summary_line" ]; then
    summary_line='RESULT: pass=unknown fail=unknown'
  fi
  test_summaries+=("$rel => $summary_line")
  test_idx=$((test_idx + 1))
done

newest_log="$(ls -1t "$RUN_DIR"/preflight_*.log 2>/dev/null | sed -n '1p' || true)"
newest_json="$(ls -1t "$RUN_DIR"/preflight_*.json 2>/dev/null | sed -n '1p' || true)"

if [ -z "$newest_log" ] || [ -z "$newest_json" ]; then
  printf 'PIPELINE RESULT: FAIL (missing preflight evidence)\n'
  exit 1
fi

bundle_json="$RUN_DIR/pipeline_bundle_${utc_stamp}.json"
bundle_sha="$RUN_DIR/pipeline_bundle_${utc_stamp}.sha256"

summary_json_payload=''
for line in "${test_summaries[@]}"; do
  escaped_line="${line//\/\\}"
  escaped_line="${escaped_line//\"/\\\"}"
  if [ -n "$summary_json_payload" ]; then
    summary_json_payload+=$'\n'
  fi
  summary_json_payload+="    \"$escaped_line\""
done

cat > "$bundle_json" <<BUNDLEEOF
{
  "schema_version": "$SCHEMA_VERSION",
  "tool_version": "$TOOL_VERSION",
  "timestamp": "$utc_stamp",
  "run_id": "$RUN_ID",
  "run_dir": "$RUN_DIR",
  "pipeline_result": "$pipeline_result",
  "test_summary": [
$summary_json_payload
  ],
  "evidence": {
    "preflight_log": "$newest_log",
    "preflight_json": "$newest_json"
  }
}
BUNDLEEOF

sha256sum "$bundle_json" "$newest_log" "$newest_json" > "$bundle_sha"

if [ "${PIPELINE_SKIP_PRUNE:-0}" != "1" ]; then
  bash "$ROOT_DIR/scripts/prune_artifacts.sh" --artifacts-dir "$ARTIFACT_DIR" > "$RUN_DIR/prune_${utc_stamp}.log" 2>&1
  cat "$RUN_DIR/prune_${utc_stamp}.log"
fi

printf 'PIPELINE RESULT: PASS\n'
printf 'Artifacts: %s\n' "$newest_log"
printf 'Artifacts: %s\n' "$newest_json"
printf 'Bundle: %s\n' "$bundle_json"
printf 'Bundle SHA256: %s\n' "$bundle_sha"
printf 'Run Dir: %s\n' "$RUN_DIR"
