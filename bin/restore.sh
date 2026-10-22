#!/usr/bin/env bash
# Recovery helpers. Read-only operations need no credentials; `push` is the
# only thing here that can modify GitHub, and it needs a write token.
set -Eeuo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"

usage() {
    cat <<'EOF'
usage: restore.sh <command> [args]

  list                          every mirrored repo, with its source
  events <owner/repo>           recorded push events, oldest first
  pinned <owner/repo>           tips preserved after force-push or deletion
  clone <owner/repo> <dir>      clone the mirror into a working tree
  push <owner/repo> <owner/new-repo>
                                force-push branches and tags into a repository
                                using $GITHUB_WRITE_TOKEN
                                (needs Contents:write and Workflows:write)

Repositories are located across all sources automatically.

Environment:
  GITHUB_WRITE_TOKEN   only needed for `push`; never mount this by default
EOF
}

# Echo the source that owns a repo, or fail.
locate() {
    local full=$1 owner=${1%%/*} repo=${1#*/} d
    for d in "$SOURCES_DIR"/*/; do
        [ -d "$d" ] || continue
        if [ -d "$d/mirrors/$owner/$repo.git" ]; then
            basename "$d"
            return 0
        fi
    done
    return 1
}

need_repo() {
    local full=$1
    SRC=$(locate "$full") || die "no mirror for $full in any source"
    DIR=$(mirror_path "$SRC" "$full")
    [ -d "$DIR" ] || die "mirror directory missing: $DIR"
}

cmd=${1:-}
case "$cmd" in
    list)
        for d in "$SOURCES_DIR"/*/; do
            [ -d "$d" ] || continue
            name=$(basename "$d")
            find "$d/mirrors" -mindepth 2 -maxdepth 2 -name '*.git' -type d 2>/dev/null \
                | sed "s|^$d/mirrors/||; s|\.git$||" | sort \
                | while read -r r; do printf '%-14s %s\n' "$name" "$r"; done
        done
        ;;

    events)
        full=${2:?owner/repo required}
        need_repo "$full"
        [ -f "$(src_ledger "$SRC")/events.jsonl" ] || die "no events recorded yet"
        jq -c --arg r "$full" 'select(.repo == $r)' "$(src_ledger "$SRC")/events.jsonl"
        ;;

    pinned)
        full=${2:?owner/repo required}
        need_repo "$full"
        if [ -f "$(src_ledger "$SRC")/pinned.tsv" ]; then
            awk -F'\t' -v r="$full" '$3 == r { printf "%s  %s  %s  %s\n", $1, $4, $5, $6 }' \
                "$(src_ledger "$SRC")/pinned.tsv"
        fi
        echo "--- refs currently held alive by refs/archive/* ---"
        git -C "$DIR" for-each-ref --format='%(refname)' refs/archive | sed 's|^refs/archive/||'
        ;;

    clone)
        full=${2:?owner/repo required}
        dest=${3:?destination directory required}
        need_repo "$full"
        git clone --no-hardlinks "$DIR" "$dest"
        ;;

    push)
        full=${2:?owner/repo required}
        target=${3:?owner/new-repo required}
        need_repo "$full"
        : "${GITHUB_WRITE_TOKEN:?set GITHUB_WRITE_TOKEN (Contents:write + Workflows:write)}"
        base=${GIT_BASE_URL#https://}
        base=${base#http://}
        url="https://x-access-token:${GITHUB_WRITE_TOKEN}@${base}/${target}.git"
        log "pushing $full -> $target from $SRC"
        # Explicit refspecs: never --mirror, which would push refs/archive/* too.
        git -C "$DIR" push --force "$url" \
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
