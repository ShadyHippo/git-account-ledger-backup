#!/usr/bin/env bash
# Outbound notification. Optional: with nothing configured this is a no-op.
#
#   notify.sh alert <title> <body> [priority]
#   notify.sh heartbeat ok|fail
#
# Two independent mechanisms, for two different failure shapes:
#
#   alert      the pass ran and something inside it failed
#   heartbeat  POST on success to an external dead-man's switch (healthchecks.io,
#              Uptime Kuma push monitor, or anything that expects a GET/POST).
#              This is the only one that can catch "the container is gone",
#              because a dead container cannot send its own failure alert.
set -Eeuo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

send_ntfy() { # title, body, priority
    [ -n "${NTFY_URL:-}" ] && [ -n "${NTFY_TOPIC:-}" ] || return 1
    curl -fsS -m 15 -X POST \
        -H "Title: $1" \
        -H "Priority: ${3:-default}" \
        -H "Tags: floppy_disk" \
        --data-binary "$2" \
        "$NTFY_URL/$NTFY_TOPIC" > /dev/null
}

send_webhook() { # title, body
    [ -n "${ALERT_URL:-}" ] || return 1
    curl -fsS -m 15 -X POST \
        -H 'Content-Type: application/json' \
        --data "$(jq -cn --arg t "$1" --arg b "$2" '{title: $t, text: $b}')" \
        "$ALERT_URL" > /dev/null
}

heartbeat() { # ok|fail
    [ -n "${HEARTBEAT_URL:-}" ] || return 0
    local url=$HEARTBEAT_URL
    [ "${1:-ok}" = "fail" ] && url="${HEARTBEAT_URL%/}/fail"
    curl -fsS -m 10 "$url" > /dev/null
}

case "${1:-}" in
    alert)
        title=${2:?title required}
        body=${3:-}
        priority=${4:-default}
        sent=0
        if [ -n "${NTFY_TOPIC:-}" ]; then
            if send_ntfy "$title" "$body" "$priority"; then sent=1; else echo "notify: ntfy failed" >&2; fi
        fi
        if [ -n "${ALERT_URL:-}" ]; then
            if send_webhook "$title" "$body"; then sent=1; else echo "notify: webhook failed" >&2; fi
        fi
        [ "$sent" -eq 1 ] || echo "notify: no notifier configured (NTFY_TOPIC / ALERT_URL unset)" >&2
        ;;
    heartbeat)
        heartbeat "${2:-ok}" || echo "notify: heartbeat ping failed" >&2
        ;;
    ""|-h|--help|help)
        echo "usage: notify.sh alert <title> <body> [priority] | notify.sh heartbeat ok|fail" >&2
        exit 2
        ;;
    *)
        echo "notify.sh: unknown command $1" >&2
        exit 2
        ;;
esac
