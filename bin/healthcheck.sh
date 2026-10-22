#!/usr/bin/env bash
# Unhealthy unless every source that is still reachable backed up recently.
# A source marked unreachable (deleted account, revoked token) is exempt: its
# mirror is intentionally frozen, not broken.
set -Eeuo pipefail

: "${ROOT:=/data}"
max=$(( ${BACKUP_INTERVAL:-3600} * 3 ))
now=$(date -u +%s)
checked=0
stale=0

[ -d "$ROOT/sources" ] || { echo "no sources yet"; exit 1; }

for d in "$ROOT/sources"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    if [ -f "$d/state/state" ] && [ "$(cat "$d/state/state")" = "unreachable" ]; then
        echo "$name: unreachable upstream (frozen, not a failure)"
        continue
    fi
    checked=$((checked + 1))
    marker="$d/state/last-backup-ok"
    if [ ! -f "$marker" ]; then
        echo "$name: no successful backup recorded yet"
        stale=$((stale + 1))
        continue
    fi
    last=$(tr -dc '0-9' < "$marker" || echo 0)
    age=$((now - ${last:-0}))
    if [ "$age" -gt "$max" ]; then
        echo "$name: stale, last success ${age}s ago (limit ${max}s)"
        stale=$((stale + 1))
    fi
done

if [ "$checked" -eq 0 ]; then
    echo "no reachable sources"
    exit 1
fi

# Verification is what proves the local copy is restorable. If it has stopped
# running, the archive is unproven, which is worth reporting.
vmark="$ROOT/verify/last-ok"
vmax=$(( ${VERIFY_INTERVAL:-604800} * 3 ))
if [ -f "$vmark" ]; then
    vepoch=$(tr -dc '0-9' < "$vmark" || echo 0)
    vage=$((now - ${vepoch:-0}))
    if [ "$vage" -gt "$vmax" ]; then
        echo "verify: last successful integrity check ${vage}s ago (limit ${vmax}s)"
        stale=$((stale + 1))
    fi
fi

if [ "$stale" -gt 0 ]; then
    echo "$stale/$checked sources stale"
    exit 1
fi
echo "ok: $checked sources fresh"
