#!/usr/bin/env bash
# Recovery helpers. Read-only operations run anywhere; `push` needs a write
# token and is the only thing in this project that can modify GitHub.
set -Eeuo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"

usage() {
    cat <<'EOF'
usage: restore.sh <command> [args]

  list                      list mirrored repositories
  pinned <owner/repo>       tips preserved after a force-push or branch delete
  events <owner/repo>       recorded push events, newest last
  clone <owner/repo> <dir>  clone the mirror to a working tree
  push <owner/repo> <owner/new-repo>
                            force-push the mirror's branches and tags into a
                            repository, using $GITHUB_WRITE_TOKEN
                            (requires Contents:write and Workflows:write)

Environment:
  GITHUB_WRITE_TOKEN   only needed for `push`; never mount this by default
EOF
}

need_mirror() {
    local full=$1
    [ -d "$MIRRORS/$full.git" ] || die "no mirror for $full"
}

cmd=${1:-}
case "$cmd" in
    list)
        find "$MIRRORS" -maxdepth 2 -name '*.git' -type d 2>/dev/null \
            | sed "s|^$MIRRORS/||; s|\.git$||" | sort
        ;;

    pinned)
        full=${2:?owner/repo required}
        need_mirror "$full"
        if [ -f "$LEDGER_DIR/pinned.tsv" ]; then
            awk -F'\t' -v r="$full" '$2 == r { printf "%s  %s  %s  %s\n", $1, $3, $4, $5 }' \
                "$LEDGER_DIR/pinned.tsv"
        fi
        echo "--- refs currently held alive by refs/archive/* ---"
        git -C "$MIRRORS/$full.git" for-each-ref --format='%(refname)' refs/archive \
            | sed 's|^refs/archive/||'
        ;;

    events)
        full=${2:?owner/repo required}
        [ -f "$LEDGER_DIR/events.jsonl" ] || die "no events recorded yet"
        jq -c --arg r "$full" 'select(.repo == $r)' "$LEDGER_DIR/events.jsonl"
        ;;

    clone)
        full=${2:?owner/repo required}
        dest=${3:?destination directory required}
        need_mirror "$full"
        git clone --no-hardlinks "$MIRRORS/$full.git" "$dest"
        ;;

    push)
        full=${2:?owner/repo required}
        target=${3:?owner/new-repo required}
        need_mirror "$full"
        : "${GITHUB_WRITE_TOKEN:?set GITHUB_WRITE_TOKEN (Contents:write + Workflows:write)}"
        base=${GIT_BASE_URL#https://}
        base=${base#http://}
        url="https://x-access-token:${GITHUB_WRITE_TOKEN}@${base}/${target}.git"
        log "pushing $full -> $target"
        # Explicit refspecs: never --mirror, or refs/archive/* would be pushed too.
        git -C "$MIRRORS/$full.git" push --force "$url" \
            'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
        ;;

    ""|-h|--help|help)
        usage
        ;;

    *)
        usage
        exit 2
        ;;
esac
