# shellcheck shell=bash
# Shared configuration and helpers for all scripts.

: "${ROOT:=/data}"
: "${API_BASE_URL:=https://api.github.com}"
: "${GIT_BASE_URL:=https://github.com}"
: "${TZ:=UTC}"

SOURCES_DIR="$ROOT/sources"
LOG_DIR="$ROOT/log"
STATUS_DIR="$ROOT/status"
BUNDLE_DIR="$ROOT/bundles"
REGISTRY="$ROOT/.sources.tsv"

export TZ
export GIT_TERMINAL_PROMPT=0

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
    local line
    line="$(ts) ${LOG_TAG:-gitarchive} $*"
    printf '%s\n' "$line" >&2
    [ -n "${LOG_FILE:-}" ] && printf '%s\n' "$line" >> "$LOG_FILE"
    return 0
}

warn() { log "WARN $*"; }
die()  { log "FATAL $*"; exit 1; }

ensure_dirs() {
    mkdir -p "$SOURCES_DIR" "$LOG_DIR" "$STATUS_DIR" "$BUNDLE_DIR"
    touch "$REGISTRY"
}

# --- per-source paths -------------------------------------------------------

src_root()    { printf '%s/%s' "$SOURCES_DIR" "$1"; }
src_mirrors() { printf '%s/%s/mirrors' "$SOURCES_DIR" "$1"; }
src_ledger()  { printf '%s/%s/ledger' "$SOURCES_DIR" "$1"; }
src_state()   { printf '%s/%s/state' "$SOURCES_DIR" "$1"; }
src_bundles() { printf '%s/%s' "$BUNDLE_DIR" "$1"; }

ensure_source_dirs() {
    mkdir -p "$(src_mirrors "$1")" "$(src_ledger "$1")" "$(src_state "$1")" "$(src_bundles "$1")"
}

mirror_path() { # source, owner/repo
    printf '%s/%s/%s.git' "$(src_mirrors "$1")" "${2%%/*}" "${2#*/}"
}

# --- tokens -----------------------------------------------------------------

read_token() { # single-token fallback used by restore helpers
    local f="${GITHUB_RO_TOKEN_FILE:-/run/secrets/github_ro}"
    if [ -n "${GITHUB_RO_TOKEN:-}" ]; then
        printf '%s' "$GITHUB_RO_TOKEN"
    elif [ -r "$f" ]; then
        tr -d '\r\n' < "$f"
    else
        return 1
    fi
}

source_token_list() { printf '%s' "${SRC_TOKENS[$1]:-}"; }

# --- API --------------------------------------------------------------------

# gh_api <token|""> <url>  -- an empty token means an anonymous request.
gh_api() {
    local token=${1:-}
    if [ -n "$token" ]; then
        curl -fsS --retry 3 --retry-delay 2 --retry-connrefused \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$2"
    else
        curl -fsS --retry 3 --retry-delay 2 --retry-connrefused \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$2"
    fi
}

# --- refspec policy ---------------------------------------------------------

# all      -> every branch
# default  -> only the repository's default branch
# a,b/*    -> only branches matching those patterns
build_refspecs() { # policy, default_branch
    local policy=$1 db=${2:-} p
    case "$policy" in
        all|"")
            printf '%s\n' '+refs/heads/*:refs/heads/*'
            ;;
        default)
            if [ -n "$db" ]; then
                printf '+refs/heads/%s:refs/heads/%s\n' "$db" "$db"
            fi
            ;;
        *)
            local IFS=,
            for p in $policy; do
                [ -n "$p" ] || continue
                printf '+refs/heads/%s:refs/heads/%s\n' "$p" "$p"
            done
            ;;
    esac
    printf '%s\n' '+refs/tags/*:refs/tags/*'
}

# --- misc -------------------------------------------------------------------

human() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]
    }'
}
