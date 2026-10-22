#!/usr/bin/env bash
# Records every PushEvent (actor, ref, before, after, forced) into an
# append-only ledger. This is the layer that catches state the hourly mirror
# cannot see: a force-push that is itself force-pushed back before the next
# fetch leaves the ref unchanged, but shows up here.
set -Eeuo pipefail
umask 077

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"

LOG_TAG=ledger
LOG_FILE="$LOG_DIR/ledger.log"
ensure_dirs

TOKEN=$(read_token) || die "no token: set GITHUB_RO_TOKEN or mount GITHUB_RO_TOKEN_FILE"
export TOKEN

exec 8>"$ROOT/.lock.ledger"
flock -n 8 || exit 0

EVENTS="$LEDGER_DIR/events.jsonl"
SEEN="$LEDGER_DIR/events.seen"
touch "$EVENTS" "$SEEN"
sort -u -o "$SEEN" "$SEEN"

if [ ! -s "$ROOT/repos.known" ]; then
    log "no repos.known yet; run a backup first"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

while read -r full; do
    [ -n "$full" ] || continue
    if ! api_get "$API_BASE_URL/repos/$full/events?per_page=100" > "$TMP/ev.json" 2>/dev/null; then
        log "events unavailable: $full"
        continue
    fi
    jq -c --arg repo "$full" '
        .[]
        | select(.type == "PushEvent")
        | { id,
            repo: $repo,
            at: .created_at,
            actor: (.actor.login // "unknown"),
            ref: (.payload.ref // ""),
            before: (.payload.before // ""),
            after: (.payload.after // ""),
            forced: (.payload.forced // false) }
    ' "$TMP/ev.json" >> "$TMP/all.jsonl" 2>/dev/null || true
done < "$ROOT/repos.known"

if [ ! -s "$TMP/all.jsonl" ]; then
    log "no push events in window"
    exit 0
fi

jq -r '.id' "$TMP/all.jsonl" | sort -u > "$TMP/ids"
comm -13 "$SEEN" "$TMP/ids" > "$TMP/fresh"

if [ ! -s "$TMP/fresh" ]; then
    exit 0
fi

jq -c --rawfile ids "$TMP/fresh" \
    'select(. as $e | (($ids | split("\n")) | index($e.id)) != null)' \
    "$TMP/all.jsonl" >> "$EVENTS"

sort -u -o "$SEEN" "$SEEN" "$TMP/fresh"
log "recorded $(wc -l < "$TMP/fresh") new push events"
