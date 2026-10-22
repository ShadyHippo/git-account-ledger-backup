#!/usr/bin/env bash
set -Eeuo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"
# shellcheck source=schedule.sh
. "$SELF_DIR/schedule.sh"

mode=${1:-loop}

CHILDREN=()

# `kill 0` is correct only when this script is PID 1 in a container; anywhere
# else it takes out the shell that launched us. Track children either way.
shutdown() {
    local p
    log "shutting down"
    if [ "$$" -eq 1 ]; then
        kill 0
    else
        for p in "${CHILDREN[@]:-}"; do
            [ -n "$p" ] && kill "$p" 2> /dev/null || true
        done
    fi
    exit 0
}

# One full pass: pin everything, record events, bundle if due, prove the result.
# Sequential on purpose: verify must look at what backup just wrote.
run_suite() {
    log "full pass: backup"
    "$SELF_DIR/backup.sh" || log "backup reported problems"
    if [ "${LEDGER_INTERVAL:-900}" -gt 0 ]; then
        log "full pass: ledger"
        "$SELF_DIR/ledger.sh" || log "ledger reported problems"
    fi
    log "full pass: bundle (self-gating on BUNDLE_INTERVAL)"
    "$SELF_DIR/bundle.sh" || log "bundle reported problems"
    log "full pass: verify"
    "$SELF_DIR/verify.sh" || log "verify reported problems"
    log "full pass: done"
}

# Sleep that can be interrupted by shutdown.
nap() {
    sleep "$1" &
    CHILDREN+=("$!")
    wait "$!" || true
}

case "$mode" in
    loop)
        ensure_dirs
        trap shutdown TERM INT

        if [ "${ONE_PASS:-0}" = "1" ]; then
            run_suite
            exit 0
        fi

        if [ -n "${SCHEDULE_AT:-}" ]; then
            valid_hhmm "$SCHEDULE_AT" \
                || die "SCHEDULE_AT must be HH:MM in 24h time, got '$SCHEDULE_AT'"

            log "nightly mode: full pass daily at $SCHEDULE_AT (${TZ:-UTC}); bundles still gate on BUNDLE_INTERVAL"

            if [ "${RUN_ON_STARTUP:-1}" = "1" ]; then
                run_suite
            else
                log "RUN_ON_STARTUP=0, waiting for the schedule"
            fi

            while :; do
                d=$(seconds_until "$SCHEDULE_AT")
                log "next full pass in $((d / 3600))h $(((d % 3600) / 60))m"
                nap "$d"
                run_suite
            done
        fi

        log "interval mode: backup every ${BACKUP_INTERVAL:-3600}s, ledger every ${LEDGER_INTERVAL:-900}s, bundles every ${BUNDLE_INTERVAL:-2592000}s, verify every ${VERIFY_INTERVAL:-604800}s"

        ( while :; do "$SELF_DIR/backup.sh" || true; sleep "${BACKUP_INTERVAL:-3600}"; done ) &
        CHILDREN+=("$!")
        if [ "${LEDGER_INTERVAL:-900}" -gt 0 ]; then
            ( sleep 30; while :; do "$SELF_DIR/ledger.sh" || true; sleep "$LEDGER_INTERVAL"; done ) &
            CHILDREN+=("$!")
        else
            log "ledger disabled (LEDGER_INTERVAL=0)"
        fi
        ( sleep 60; while :; do "$SELF_DIR/bundle.sh" || true; sleep 300; done ) &
        CHILDREN+=("$!")
        ( sleep 120; while :; do "$SELF_DIR/verify.sh" || true; sleep "${VERIFY_INTERVAL:-604800}"; done ) &
        CHILDREN+=("$!")

        wait
        ;;

    backup|ledger|bundle|healthcheck|stats|verify)
        exec "$SELF_DIR/$mode.sh"
        ;;

    *)
        echo "usage: entrypoint.sh [loop|backup|ledger|bundle|healthcheck|stats|verify]" >&2
        echo "       ONE_PASS=1 entrypoint.sh loop   run one full pass and exit" >&2
        echo "       destructive maintenance uses snapshot.sh directly:" >&2
        echo "       docker exec gitarchive /usr/local/bin/snapshot.sh --help" >&2
        exit 2
        ;;
esac
