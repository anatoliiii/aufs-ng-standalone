#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s\n' "$*"
}

measure() {
  local label=$1
  shift
  local start end
  start=$(date +%s%N)
  "$@"
  end=$(date +%s%N)
  local delta_ns=$((end - start))
  local delta_ms=$((delta_ns / 1000000))
  log "METRIC ${label}_ms=${delta_ms}"
}

WORKDIR=$(mktemp -d)
cleanup() {
  set +e
  umount "${WORKDIR}/mnt" 2>/dev/null || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${WORKDIR}"/{lowerA,lowerB,upper,work,mnt}

touch "${WORKDIR}/lowerA/base"{1..10}
for i in $(seq 1 50); do
  printf 'base-%04d\n' "$i" > "${WORKDIR}/lowerB/file${i}"
  mkdir -p "${WORKDIR}/lowerB/dir${i}"
  printf 'nested-%04d\n' "$i" > "${WORKDIR}/lowerB/dir${i}/payload"
  chmod 555 "${WORKDIR}/lowerB/dir${i}"

done

log "== AUCONF PRESETS =="
./tools/auconf --list-presets

log "== OVERLAY MOUNT =="
./tools/unionctl --backend overlay --dry-run mount \
  --target "${WORKDIR}/mnt" \
  --lowerdir "${WORKDIR}/lowerB:${WORKDIR}/lowerA" \
  --upperdir "${WORKDIR}/upper" \
  --workdir "${WORKDIR}/work"

date +%s >/dev/null # warmup time utility

log "== REAL MOUNT EXECUTION =="
if ./tools/unionctl --backend overlay mount \
  --target "${WORKDIR}/mnt" \
  --lowerdir "${WORKDIR}/lowerB:${WORKDIR}/lowerA" \
  --upperdir "${WORKDIR}/upper" \
  --workdir "${WORKDIR}/work"; then
  log "== LIST =="
  ./tools/unionctl --backend overlay list

  log "== FILE CREATE BENCH =="
  measure overlay_create bash -c '
    for i in $(seq 1 200); do
      printf "data-%04d\n" "$i" > "${WORKDIR}/mnt/new${i}"
    done
  '

  log "== REORDER (DRY-RUN) =="
  ./tools/unionctl --backend overlay --dry-run reorder \
    --target "${WORKDIR}/mnt" \
    ${WORKDIR}/lowerA ${WORKDIR}/lowerB

  log "== UMOUNT =="
  ./tools/unionctl --backend overlay umount "${WORKDIR}/mnt"
else
  log "WARN overlay mount failed; skipping runtime smoke metrics"
fi
