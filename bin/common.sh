# shellcheck shell=bash
# Shared configuration and helpers for all scripts.

: "${ROOT:=/data}"
: "${API_BASE_URL:=https://api.github.com}"
: "${GIT_BASE_URL:=https://github.com}"
: "${TZ:=UTC}"

MIRRORS="$ROOT/mirrors"
LEDGER_DIR="$ROOT/ledger"
LOG_DIR="$ROOT/log"
STATUS_DIR="$ROOT/status"
BUNDLE_DIR="$ROOT/bundles"

export TZ
export GIT_TERMINAL_PROMPT=0

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Timestamped line to stderr and to the script's log file.
log() {
    local line
    line="$(ts) ${LOG_TAG:-gitarchive} $*"
    printf '%s\n' "$line" >&2
    [ -n "${LOG_FILE:-}" ] && printf '%s\n' "$line" >> "$LOG_FILE"
    return 0
}

die() { log "FATAL $*"; exit 1; }

ensure_dirs() {
    mkdir -p "$MIRRORS" "$LEDGER_DIR" "$LOG_DIR" "$STATUS_DIR"
}

# Token from env, or from a file mount. Prints the token, returns 1 if absent.
read_token() {
    local f="${GITHUB_RO_TOKEN_FILE:-/run/secrets/github_ro}"
    if [ -n "${GITHUB_RO_TOKEN:-}" ]; then
        printf '%s' "$GITHUB_RO_TOKEN"
    elif [ -r "$f" ]; then
        tr -d '\r\n' < "$f"
    else
        return 1
    fi
}

api_get() {
    curl -fsS --retry 3 --retry-delay 2 --retry-connrefused \
        -H "Authorization: Bearer ${TOKEN:?}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$@"
}
