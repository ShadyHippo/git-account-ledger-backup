#!/usr/bin/env bash
# Unhealthy if the last fully successful backup is older than 3 intervals.
set -Eeuo pipefail

: "${ROOT:=/data}"
marker="$ROOT/status/last-backup-ok"
max=$(( ${BACKUP_INTERVAL:-3600} * 3 ))

[ -f "$marker" ] || { echo "no successful backup recorded yet"; exit 1; }
last=$(tr -dc '0-9' < "$marker" || echo 0)
age=$(( $(date -u +%s) - ${last:-0} ))
if [ "$age" -gt "$max" ]; then
    echo "stale: last successful backup ${age}s ago (limit ${max}s)"
    exit 1
fi
echo "ok: last successful backup ${age}s ago"
