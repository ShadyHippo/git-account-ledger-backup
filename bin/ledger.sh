#!/usr/bin/env bash
# Records every PushEvent per source into an append-only ledger.
#
# This is the layer that catches what the periodic mirror structurally cannot:
# a force-push that is itself force-pushed back leaves the ref unchanged by the
# time the mirror looks, but shows up here with both SHAs.
set -Eeuo pipefail
umask 077

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"
# shellcheck source=config.sh
. "$SELF_DIR/config.sh"

LOG_TAG=ledger
LOG_FILE="$LOG_DIR/ledger.log"
ensure_dirs
load_config

exec 8>"$ROOT/.lock.ledger"
flock -n 8 || exit 0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

recorded=0
for name in "${SOURCE_NAMES[@]}"; do
    ledger="$(src_ledger "$name")"
    state="$(src_state "$name")"
    mkdir -p "$ledger"
    EVENTS="$ledger/events.jsonl"
    SEEN="$ledger/events.seen"
    touch "$EVENTS" "$SEEN"
    sort -u -o "$SEEN" "$SEEN"

    [ -s "$state/repos.tsv" ] || continue

    token=$(source_token_list "$name" | awk '{print $1}')
    : > "$TMP/$name.jsonl"

    while IFS=$'\t' read -r full _db; do
        [ -n "$full" ] || continue
        if ! gh_api "$token" "$API_BASE_URL/repos/$full/events?per_page=100" > "$TMP/ev.json" 2>/dev/null; then
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
        ' "$TMP/ev.json" >> "$TMP/$name.jsonl" 2>/dev/null || true
    done < "$state/repos.tsv"

    [ -s "$TMP/$name.jsonl" ] || continue

    jq -r '.id' "$TMP/$name.jsonl" | sort -u > "$TMP/$name.ids"
    comm -13 "$SEEN" "$TMP/$name.ids" > "$TMP/$name.fresh"
    [ -s "$TMP/$name.fresh" ] || continue

    jq -c --rawfile ids "$TMP/$name.fresh" \
        'select(. as $e | (($ids | split("\n")) | index($e.id)) != null)' \
        "$TMP/$name.jsonl" >> "$EVENTS"

    sort -u -o "$SEEN" "$SEEN" "$TMP/$name.fresh"
    n=$(wc -l < "$TMP/$name.fresh")
    recorded=$((recorded + n))
    log "$name: recorded $n new push events"
done

log "ledger finished: $recorded new events"
