#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRUNE="$ROOT_DIR/scripts/prune_artifacts.sh"

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

assert_contains() {
  name="$1"
  file="$2"
  expected_text="$3"
  if grep -Fq "$expected_text" "$file"; then
    printf 'PASS: %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (missing=%s)\n' "$name" "$expected_text"
    fail_count=$((fail_count + 1))
  fi
}

assert_file_present() {
  name="$1"
  file="$2"
  if [ -f "$file" ]; then
    printf 'PASS: %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (missing=%s)\n' "$name" "$file"
    fail_count=$((fail_count + 1))
  fi
}

assert_path_present() {
  name="$1"
  path="$2"
  if [ -e "$path" ]; then
    printf 'PASS: %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (missing=%s)\n' "$name" "$path"
    fail_count=$((fail_count + 1))
  fi
}

assert_file_missing() {
  name="$1"
  file="$2"
  if [ ! -e "$file" ]; then
    printf 'PASS: %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s (still exists=%s)\n' "$name" "$file"
    fail_count=$((fail_count + 1))
  fi
}

assert_exit_contains 'unknown arg denied' 2 'unknown argument' "$PRUNE" --bad-arg
assert_exit_contains 'invalid keep days denied' 2 'non-negative integer' "$PRUNE" --keep-days -1

art_dir="$tmp_root/artifacts"
mkdir -p "$art_dir"
mkdir -p "$art_dir/runs/run_old" "$art_dir/runs/run_new"
: > "$art_dir/.gitkeep"
printf 'a' > "$art_dir/old1.bin"
printf 'b' > "$art_dir/old2.bin"
printf 'c' > "$art_dir/old3.bin"
printf 'd' > "$art_dir/new1.bin"

touch -d '40 days ago' "$art_dir/old1.bin"
touch -d '30 days ago' "$art_dir/old2.bin"
touch -d '20 days ago' "$art_dir/old3.bin"
touch -d '1 day ago' "$art_dir/new1.bin"
touch -d '40 days ago' "$art_dir/runs/run_old"
touch -d '1 day ago' "$art_dir/runs/run_new"

dry_out="$tmp_root/prune_dry.log"
"$PRUNE" --artifacts-dir "$art_dir" --keep-days 14 --keep-count 0 --dry-run > "$dry_out"
assert_contains 'dry run reports candidates' "$dry_out" 'delete_candidates=4'
assert_contains 'dry run deterministic delete list' "$dry_out" 'delete_list=old1.bin,old2.bin,old3.bin,runs/run_old'
assert_file_present 'dry run keeps old1 present' "$art_dir/old1.bin"

real_out="$tmp_root/prune_real.log"
"$PRUNE" --artifacts-dir "$art_dir" --keep-days 14 --keep-count 0 > "$real_out"
assert_contains 'real run reports deleted count' "$real_out" 'deleted=4'
assert_file_missing 'real run removed old1' "$art_dir/old1.bin"
assert_file_missing 'real run removed old2' "$art_dir/old2.bin"
assert_file_missing 'real run removed old3' "$art_dir/old3.bin"
assert_file_missing 'real run removed old run dir' "$art_dir/runs/run_old"
assert_file_present 'real run preserved new1 by age' "$art_dir/new1.bin"
assert_path_present 'real run preserved new run dir by age' "$art_dir/runs/run_new"
assert_file_present 'real run preserved .gitkeep' "$art_dir/.gitkeep"

printf 'RESULT: pass=%s fail=%s\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
