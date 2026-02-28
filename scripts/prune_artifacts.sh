#!/usr/bin/env bash

set -euo pipefail

ARTIFACTS_DIR="artifacts"
KEEP_DAYS=14
KEEP_COUNT=200
DRY_RUN=0

usage() {
  cat <<'EOU'
Usage:
  prune_artifacts.sh [--artifacts-dir PATH] [--keep-days N] [--keep-count N] [--dry-run]
EOU
}

fail_usage() {
  printf 'USAGE: %s\n' "$1" >&2
  usage >&2
  exit 2
}

is_non_negative_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifacts-dir)
      [ "$#" -ge 2 ] || fail_usage 'missing value for --artifacts-dir'
      ARTIFACTS_DIR="$2"
      shift 2
      ;;
    --keep-days)
      [ "$#" -ge 2 ] || fail_usage 'missing value for --keep-days'
      KEEP_DAYS="$2"
      shift 2
      ;;
    --keep-count)
      [ "$#" -ge 2 ] || fail_usage 'missing value for --keep-count'
      KEEP_COUNT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

is_non_negative_int "$KEEP_DAYS" || fail_usage '--keep-days must be a non-negative integer'
is_non_negative_int "$KEEP_COUNT" || fail_usage '--keep-count must be a non-negative integer'

[ -d "$ARTIFACTS_DIR" ] || fail_usage "artifacts directory not found: $ARTIFACTS_DIR"

now_epoch="$(date -u +%s)"
cutoff_epoch=$((now_epoch - KEEP_DAYS * 86400))

scan_tmp="$(mktemp)"
delete_tmp="$(mktemp)"

cleanup() {
  rm -f "$scan_tmp" "$delete_tmp"
}
trap cleanup EXIT

find "$ARTIFACTS_DIR" -maxdepth 1 -type f ! -name '.gitkeep' ! -name '.pipeline.lock' -printf 'file\t%f\t%T@\t%s\n' | LC_ALL=C sort -t $'\t' -k3,3nr -k2,2 >> "$scan_tmp"
if [ -d "$ARTIFACTS_DIR/runs" ]; then
  find "$ARTIFACTS_DIR/runs" -mindepth 1 -maxdepth 1 -type d -printf 'run_dir\truns/%f\t%T@\t0\n' | LC_ALL=C sort -t $'\t' -k3,3nr -k2,2 >> "$scan_tmp"
fi
LC_ALL=C sort -t $'\t' -k3,3nr -k2,2 "$scan_tmp" -o "$scan_tmp"

total_files=0
kept_files=0
delete_candidates=0
bytes_planned=0

rank=0
while IFS=$'\t' read -r entry_type name mtime_raw size; do
  [ -n "$name" ] || continue
  rank=$((rank + 1))
  total_files=$((total_files + 1))

  mtime_int="$(printf '%.0f' "$mtime_raw" 2>/dev/null || printf '0')"

  keep_by_count=0
  if [ "$rank" -le "$KEEP_COUNT" ]; then
    keep_by_count=1
  fi

  keep_by_age=0
  if [ "$mtime_int" -ge "$cutoff_epoch" ]; then
    keep_by_age=1
  fi

  if [ "$keep_by_count" -eq 1 ] || [ "$keep_by_age" -eq 1 ]; then
    kept_files=$((kept_files + 1))
    continue
  fi

  delete_candidates=$((delete_candidates + 1))
  bytes_planned=$((bytes_planned + size))
  printf '%s\t%s\n' "$entry_type" "$name" >> "$delete_tmp"
done < "$scan_tmp"

deleted_count=0
bytes_deleted=0
if [ "$DRY_RUN" -eq 0 ] && [ -s "$delete_tmp" ]; then
  while IFS=$'\t' read -r entry_type name; do
    [ -n "$name" ] || continue
    file_path="$ARTIFACTS_DIR/$name"
    case "$entry_type" in
      file)
        [ -f "$file_path" ] || continue
        size_now="$(stat -c '%s' "$file_path" 2>/dev/null || printf '0')"
        if rm -f "$file_path"; then
          deleted_count=$((deleted_count + 1))
          bytes_deleted=$((bytes_deleted + size_now))
        fi
        ;;
      run_dir)
        [ -d "$file_path" ] || continue
        size_now='0'
        if rm -rf "$file_path"; then
          deleted_count=$((deleted_count + 1))
          bytes_deleted=$((bytes_deleted + size_now))
        fi
        ;;
      *)
        continue
        ;;
    esac
  done < <(LC_ALL=C sort -t $'\t' -k2,2 "$delete_tmp")
fi

if [ -s "$delete_tmp" ]; then
  delete_list="$(LC_ALL=C sort -t $'\t' -k2,2 "$delete_tmp" | cut -f2 | paste -sd ',' -)"
else
  delete_list=''
fi

printf 'prune_summary artifacts_dir=%s total_files=%s keep_days=%s keep_count=%s dry_run=%s\n' "$ARTIFACTS_DIR" "$total_files" "$KEEP_DAYS" "$KEEP_COUNT" "$DRY_RUN"
printf 'prune_summary kept=%s delete_candidates=%s deleted=%s bytes_planned=%s bytes_deleted=%s\n' "$kept_files" "$delete_candidates" "$deleted_count" "$bytes_planned" "$bytes_deleted"
printf 'delete_list=%s\n' "$delete_list"

exit 0
