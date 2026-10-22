#!/usr/bin/env bash
# Recovery helpers. Read-only operations need no credentials; `push` is the
# only thing here that can modify GitHub, and it needs a write token.
set -Eeuo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"

TMP_STATE=$(mktemp)
trap 'rm -f "$TMP_STATE"' EXIT

usage() {
    cat <<'EOF'
usage: restore.sh <command> [args]

  list                          every mirrored repo, with its source
  events <owner/repo>           recorded push events, oldest first
  pinned <owner/repo>           tips preserved after force-push or deletion
  state <owner/repo> <when> [dir]
                                what each branch pointed at, as of an ISO
                                timestamp, reconstructed from the ledger.
                                With [dir], clone and create those branches.
  rescue <owner/repo> <sha>     fetch one commit from upstream and pin it.
                                For a SHA the ledger recorded but that was
                                never fetched (see Limitations in README).
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

    state)
        full=${2:?owner/repo required}
        when=${3:?ISO timestamp required, e.g. 2026-10-21T14:00:00Z}
        dest=${4:-}
        need_repo "$full"
        if [ "$when" = "now" ]; then
            git -C "$DIR" for-each-ref --format='%(refname:short) %(objectname)' refs/heads
            exit 0
        fi
        ev="$(src_ledger "$SRC")/events.jsonl"
        [ -f "$ev" ] || die "no events recorded yet; cannot reconstruct $when"
        jq -sr --arg r "$full" --arg t "$when" '
            [ .[] | select(.repo == $r and .at <= $t) ]
            | sort_by(.ref)
            | group_by(.ref)
            | map(. as $g | { ref: $g[0].ref, tip: ($g | sort_by(.at) | last | .after) })
            | .[]
            | [.ref, .tip] | @tsv
        ' "$ev" > "$TMP_STATE"
        if [ ! -s "$TMP_STATE" ]; then
            die "no recorded pushes at or before $when"
        fi
        if [ -n "$dest" ]; then
            git clone -q --no-hardlinks "$DIR" "$dest" || die "clone failed"
            # Detach so branches can be moved freely, then re-attach at the end.
            git -C "$dest" checkout -q --detach 2>/dev/null || true
        fi
        while IFS=$'\t' read -r ref tip; do
            short=${ref#refs/heads/}
            case "$tip" in
                0000000000000000000000000000000000000000)
                    printf '%-28s %s  DELETED at this time\n' "$short" "-"
                    continue
                    ;;
            esac
            if git -C "$DIR" cat-file -e "$tip^{commit}" 2>/dev/null; then
                printf '%-28s %s  present\n' "$short" "$tip"
                if [ -n "$dest" ]; then
                    git -C "$dest" branch -f "$short" "$tip" > /dev/null 2>&1 || true
                fi
            else
                printf '%-28s %s  MISSING -> restore.sh rescue %s %s\n' \
                    "$short" "$tip" "$full" "$tip"
            fi
        done < "$TMP_STATE"
        if [ -n "$dest" ]; then
            pick=""
            for cand in main master trunk; do
                if git -C "$dest" rev-parse -q --verify "refs/heads/$cand" > /dev/null 2>&1; then
                    pick=$cand
                    break
                fi
            done
            [ -n "$pick" ] || pick=$(git -C "$dest" for-each-ref --count=1 --format='%(refname:short)' refs/heads)
            [ -n "$pick" ] && git -C "$dest" checkout -q "$pick" 2>/dev/null || true
            printf '\nbranches created in %s (checked out: %s)\n' "$dest" "${pick:-none}"
        fi
        ;;

    rescue)
        full=${2:?owner/repo required}
        sha=${3:?full 40-character sha required}
        need_repo "$full"
        case "$sha" in
            *[!0-9a-f]*|"") die "not a lowercase hex sha: $sha" ;;
        esac
        [ "${#sha}" -eq 40 ] || die "expected a full 40-character sha, got ${#sha} characters"
        [ "$sha" = "0000000000000000000000000000000000000000" ] \
            && die "that is a deletion marker, not a commit"
        if ! git -C "$DIR" cat-file -e "$sha^{commit}" 2>/dev/null; then
            TOKEN=$(read_token) || die "rescue needs a token, read-only is enough"
            log "fetching $sha from upstream"
            GITHUB_RO_TOKEN="$TOKEN" git -C "$DIR" -c credential.helper="$SELF_DIR/cred-helper" \
                fetch -q origin "$sha" 2>/dev/null \
                || die "upstream no longer has $sha (collected, or the server forbids fetch-by-sha)"
        fi
        git -C "$DIR" update-ref "refs/archive/$sha" "$sha"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$SRC" "$full" "rescue" "$sha" "from-ledger" \
            >> "$(src_ledger "$SRC")/pinned.tsv"
        echo "rescued $sha into refs/archive/$sha"
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
