#!/usr/bin/env bash
# Reports where the space actually goes. Answers "how big is this really"
# with your data instead of a guess.
set -Eeuo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"

size_kb() { du -sk "$1" 2>/dev/null | cut -f1 || echo 0; }

[ -d "$SOURCES_DIR" ] || die "no sources yet at $SOURCES_DIR"

grand=0
grand_pinned=0
grand_repos=0

for d in "$SOURCES_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    state="$d/state"
    total=0
    repos=0
    pinned_total=0
    printf '\n\033[1m%s\033[0m\n' "$name"

    if [ -s "$state/repos.tsv" ]; then
        while IFS=$'\t' read -r full _db; do
            [ -n "$full" ] || continue
            dir=$(mirror_path "$name" "$full")
            repos=$((repos + 1))
            if [ ! -d "$dir" ]; then
                printf '  %-44s %10s\n' "$full" MISSING
                continue
            fi
            kb=$(size_kb "$dir")
            total=$((total + kb))
            p=$(git -C "$dir" for-each-ref --format=x refs/archive | wc -l)
            pinned_total=$((pinned_total + p))
            commits=$(git -C "$dir" rev-list --count --all 2>/dev/null || echo 0)
            shallow=""
            [ -f "$dir/shallow" ] && shallow=" shallow"
            printf '  %-44s %10s %7s commits %5s pinned%s\n' \
                "$full" "$(human $((kb * 1024)))" "$commits" "$p" "$shallow"
        done < "$state/repos.tsv"
    fi

    bkb=0
    [ -d "$(src_bundles "$name")" ] && bkb=$(size_kb "$(src_bundles "$name")")
    printf '  %-44s %10s %7s repos  %5s pinned\n' \
        "TOTAL $name" "$(human $((total * 1024)))" "$repos" "$pinned_total"
    printf '  %-44s %10s\n' "bundles $name" "$(human $((bkb * 1024)))"

    grand=$((grand + total + bkb))
    grand_pinned=$((grand_pinned + pinned_total))
    grand_repos=$((grand_repos + repos))
done

printf '\n\033[1m%-46s %10s\033[0m\n' "everything" "$(human $((grand * 1024)))"
printf '%-46s %10s\n' "repositories" "$grand_repos"
printf '%-46s %10s\n' "pinned tips" "$grand_pinned"
printf '\nSpace is dominated by content, not history. Run this after a few\n'
printf 'bundle generations to see what retention is really costing you.\n'
