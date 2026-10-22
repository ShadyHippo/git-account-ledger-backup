#!/usr/bin/env bash
set -Eeuo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"

mode=${1:-loop}

case "$mode" in
    loop)
        ensure_dirs
        log "starting: backup every ${BACKUP_INTERVAL:-3600}s, ledger every ${LEDGER_INTERVAL:-900}s, bundles every ${BUNDLE_INTERVAL:-2592000}s"
        trap 'log "shutting down"; kill 0' TERM INT

        ( while :; do "$SELF_DIR/backup.sh" || true; sleep "${BACKUP_INTERVAL:-3600}"; done ) &
        if [ "${LEDGER_INTERVAL:-900}" -gt 0 ]; then
            ( sleep 30; while :; do "$SELF_DIR/ledger.sh" || true; sleep "$LEDGER_INTERVAL"; done ) &
        else
            log "ledger disabled (LEDGER_INTERVAL=0); pinning and verification are unaffected"
        fi
        ( sleep 60; while :; do "$SELF_DIR/bundle.sh" || true; sleep 300; done ) &
        ( sleep 120; while :; do "$SELF_DIR/verify.sh" || true; sleep "${VERIFY_INTERVAL:-604800}"; done ) &

        wait
        ;;

    backup|ledger|bundle|healthcheck|stats|verify)
        exec "$SELF_DIR/$mode.sh"
        ;;

    *)
        echo "usage: entrypoint.sh [loop|backup|ledger|bundle|healthcheck|stats|verify]" >&2
        echo "       for destructive maintenance use snapshot.sh directly:" >&2
        echo "       docker exec gitarchive /usr/local/bin/snapshot.sh --help" >&2
        exit 2
        ;;
esac
