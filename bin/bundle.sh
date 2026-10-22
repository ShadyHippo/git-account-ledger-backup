#!/usr/bin/env bash
# Monthly: export a self-contained bundle per repo, then repack and prune.
#
# The repack is also an audit: everything reachable from refs/archive/* survives
# `prune`, so if a tip you expected to be pinned disappears here, pinning broke.
set -Eeuo pipefail
umask 077

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"

LOG_TAG=bundle
LOG_FILE="$LOG_DIR/bundle.log"
ensure_dirs

exec 9>"$ROOT/.lock.mirror"
flock -n 9 || { log "another mirror job holds the lock, skipping"; exit 0; }

# Self-gating: the entrypoint polls every few minutes, so only run when due.
MARK="$STATUS_DIR/last-bundle"
now=$(date -u +%s)
if [ -f "$MARK" ]; then
    last=$(tr -dc '0-9' < "$MARK" || echo 0)
    if [ $((now - ${last:-0})) -lt "${BUNDLE_INTERVAL:-2592000}" ]; then
        exit 0
    fi
fi

[ -s "$ROOT/repos.known" ] || { log "no repos.known yet; run a backup first"; exit 0; }

STAMP=$(date -u +%Y-%m)
OUT="$BUNDLE_DIR/$STAMP"
failed=0
count=0

while read -r full; do
    [ -n "$full" ] || continue
    dir="$MIRRORS/$full.git"
    if [ ! -d "$dir" ]; then
        continue
    fi
    # `bundle create --all` refuses to write an empty bundle.
    if [ -z "$(git -C "$dir" for-each-ref --count=1 --format='%(refname)' 2>/dev/null)" ]; then
        continue
    fi

    mkdir -p -- "$(dirname -- "$OUT/$full.bundle")"
    if ! git -C "$dir" bundle create -q "$OUT/$full.bundle" --all; then
        log "bundle failed: $full"
        failed=$((failed + 1))
        continue
    fi
    if ! git -C "$dir" bundle verify -q "$OUT/$full.bundle" > /dev/null 2>&1; then
        log "bundle verify FAILED: $full"
        failed=$((failed + 1))
        continue
    fi

    # Consolidated pack; unreachable objects go away, pinned ones do not.
    git -C "$dir" repack -adq
    git -C "$dir" prune --expire=2.weeks.ago > /dev/null 2>&1 || true

    count=$((count + 1))
done < "$ROOT/repos.known"

log "bundled $count repos into $OUT ($failed failed)"
if [ "$failed" -eq 0 ]; then
    printf '%s\n' "$now" > "$MARK"
else
    exit 1
fi
