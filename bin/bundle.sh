#!/usr/bin/env bash
# Monthly per source: a self-contained bundle per repo, then repack and prune.
#
# The repack is also an audit: everything reachable from refs/archive/* survives
# `prune`, so a tip you expected to be pinned disappearing here means pinning
# broke.
#
# Bundles do not deduplicate, so old generations are deleted down to
# BUNDLE_KEEP. That is the one place this project deletes anything, and it is
# deleting a copy, never the archive.
set -Eeuo pipefail
umask 077

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"
# shellcheck source=config.sh
. "$SELF_DIR/config.sh"

LOG_TAG=bundle
LOG_FILE="$LOG_DIR/bundle.log"
ensure_dirs
load_config

exec 9>"$ROOT/.lock.mirror"
flock -n 9 || { log "another mirror job holds the lock, skipping"; exit 0; }

MARK="$STATUS_DIR/last-bundle"
now=$(date -u +%s)
if [ -f "$MARK" ]; then
    last=$(tr -dc '0-9' < "$MARK" || echo 0)
    if [ $((now - ${last:-0})) -lt "${BUNDLE_INTERVAL:-2592000}" ]; then
        exit 0
    fi
fi

STAMP=$(date -u +%Y-%m)
overall=0
count=0
failed=0

for name in "${SOURCE_NAMES[@]}"; do
    state="$(src_state "$name")"
    out="$(src_bundles "$name")/$STAMP"
    [ -s "$state/repos.tsv" ] || continue

    while IFS=$'\t' read -r full _db; do
        [ -n "$full" ] || continue
        dir=$(mirror_path "$name" "$full")
        [ -d "$dir" ] || continue
        if [ -z "$(git -C "$dir" for-each-ref --count=1 --format='%(refname)' 2>/dev/null)" ]; then
            continue
        fi

        mkdir -p -- "$(dirname -- "$out/$full.bundle")"
        if ! git -C "$dir" bundle create -q "$out/$full.bundle" --all; then
            log "bundle failed: $name $full"
            failed=$((failed + 1))
            continue
        fi
        if ! git -C "$dir" bundle verify -q "$out/$full.bundle" > /dev/null 2>&1; then
            log "bundle verify FAILED: $name $full"
            failed=$((failed + 1))
            continue
        fi

        git -C "$dir" repack -adq
        git -C "$dir" prune --expire=2.weeks.ago > /dev/null 2>&1 || true
        count=$((count + 1))
    done < "$state/repos.tsv"

    # Retention: newest BUNDLE_KEEP generations.
    keep=${BUNDLE_KEEP:-6}
    ls -1d "$(src_bundles "$name")"/[0-9][0-9][0-9][0-9]-[0-9][0-9] 2>/dev/null \
        | sort -r | tail -n +$((keep + 1)) | while read -r old; do
            log "$name: dropping old bundle generation $(basename "$old")"
            rm -rf -- "$old"
        done
done

log "bundled $count repos ($failed failed)"
if [ "$failed" -eq 0 ]; then
    printf '%s\n' "$now" > "$MARK"
else
    overall=1
fi
exit "$overall"
