#!/usr/bin/env bash
# Offline proof that the local archive is intact and restorable.
#
# Deliberately touches no network. Everything checked here is a statement about
# what is on this machine, not about GitHub:
#
#   1. every mirror directory still exists
#   2. git fsck reports no missing or broken objects
#   3. every commit ever promised in pinned.tsv still resolves
#   4. a sample of those commits can actually be materialised (blobs included)
#
# It prints a digest of the archive's ref state, so two runs can be compared and
# a single short string can be recorded elsewhere as an attestation.
set -Eeuo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"

LOG_TAG=verify
LOG_FILE="$LOG_DIR/verify.log"
VERIFY_DIR="$ROOT/verify"
ensure_dirs
mkdir -p "$VERIFY_DIR"

MODE=connectivity
DRILL=3
while [ $# -gt 0 ]; do
    case "$1" in
        --full)     MODE=full; shift ;;
        --no-drill) DRILL=0; shift ;;
        --drill)    DRILL=${2:-3}; shift 2 ;;
        -h|--help)
            cat <<'EOF'
usage: verify.sh [options]

  --full       fsck every object, not just connectivity (slow, catches bit rot)
  --drill N    materialise N sampled pinned commits per repo (default 3)
  --no-drill   skip materialisation

Exit status is 0 only if every check passes. No network access is used.
EOF
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -d "$SOURCES_DIR" ] || die "no sources at $SOURCES_DIR"

errors=0
total_repos=0
total_refs=0
total_pins=0
total_bytes=0
digest_input=$(mktemp)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$digest_input"' EXIT

fail() { log "FAIL $*"; errors=$((errors + 1)); }

printf '%-16s %6s %6s %6s %10s\n' SOURCE REPOS REFS PINS SIZE

for d in "$SOURCES_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    state="$d/state"
    ledger="$d/ledger"
    [ -f "$state/repos.known" ] || continue

    s_repos=0
    s_refs=0
    s_pins=0
    s_bytes=0

    while read -r full; do
        [ -n "$full" ] || continue
        dir=$(mirror_path "$name" "$full")
        s_repos=$((s_repos + 1))

        if [ ! -d "$dir" ]; then
            fail "$name $full: mirror directory is gone"
            continue
        fi

        # 1/2. object store integrity
        if [ "$MODE" = "full" ]; then
            out=$(git -C "$dir" fsck --full --strict --no-progress 2>&1) || {
                fail "$name $full: fsck"
                printf '%s\n' "$out" | sed 's/^/    /' >> "$LOG_FILE"
            }
        else
            out=$(git -C "$dir" fsck --connectivity-only --no-progress --no-dangling 2>&1) || {
                fail "$name $full: fsck"
                printf '%s\n' "$out" | sed 's/^/    /' >> "$LOG_FILE"
            }
            # A repo with no refs only produces a notice; ignore it.
            case "$out" in
                *"No default references"*) out="" ;;
            esac
            if [ -n "$out" ] && printf '%s' "$out" | grep -qv '^notice:'; then
                fail "$name $full: fsck reported objects"
                printf '%s\n' "$out" | sed 's/^/    /' >> "$LOG_FILE"
            fi
        fi

        nrefs=$(git -C "$dir" for-each-ref --format=x refs/heads refs/tags refs/archive | wc -l)
        s_refs=$((s_refs + nrefs))

        # 3. every pin we ever promised must still resolve
        pinlist="$TMP/pins"
        : > "$pinlist"
        if [ -f "$ledger/pinned.tsv" ]; then
            awk -F'\t' -v r="$full" '$3 == r { print $5 }' "$ledger/pinned.tsv" > "$pinlist"
        fi
        npins=$(wc -l < "$pinlist")
        s_pins=$((s_pins + npins))

        while read -r sha; do
            [ -n "$sha" ] || continue
            if ! git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null; then
                fail "$name $full: pinned commit $sha is no longer in the object store"
            fi
        done < "$pinlist"

        # 4. restorability drill: read whole trees, blobs included
        if [ "$DRILL" -gt 0 ] && [ "$npins" -gt 0 ]; then
            step=$((npins / DRILL))
            [ "$step" -lt 1 ] && step=1
            awk -v s="$step" 'NR % s == 1' "$pinlist" | head -n "$DRILL" > "$TMP/sample"
            while read -r sha; do
                [ -n "$sha" ] || continue
                if ! git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null; then
                    continue   # already reported above
                fi
                if ! bytes=$(git -C "$dir" archive "$sha" 2>/dev/null | wc -c); then
                    fail "$name $full: cannot materialise $sha"
                elif [ "${bytes:-0}" -le 0 ]; then
                    fail "$name $full: materialising $sha produced nothing"
                fi
            done < "$TMP/sample"
        fi

        kb=$(du -sk "$dir" 2>/dev/null | cut -f1 || echo 0)
        s_bytes=$((s_bytes + kb))

        refsfp=$(git -C "$dir" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags refs/archive \
            | sort | sha256sum | cut -d' ' -f1)
        printf '%s %s %s\n' "$name" "$full" "$refsfp" >> "$digest_input"
    done < "$state/repos.known"

    printf '%-16s %6s %6s %6s %10s\n' "$name" "$s_repos" "$s_refs" "$s_pins" "$(human $((s_bytes * 1024)))"
    total_repos=$((total_repos + s_repos))
    total_refs=$((total_refs + s_refs))
    total_pins=$((total_pins + s_pins))
    total_bytes=$((total_bytes + s_bytes))
done

digest=$(sort "$digest_input" | sha256sum | cut -d' ' -f1)
when=$(ts)

printf '\n'
printf 'repos      %s\n' "$total_repos"
printf 'refs       %s\n' "$total_refs"
printf 'pinned     %s\n' "$total_pins"
printf 'size       %s\n' "$(human $((total_bytes * 1024)))"
printf 'digest     sha256:%s\n' "$digest"

printf '%s\t%s\t%s\t%s\t%s\tsha256:%s\n' \
    "$when" "$total_repos" "$total_refs" "$total_pins" "$MODE" "$digest" >> "$VERIFY_DIR/history.tsv"

if [ "$errors" -gt 0 ]; then
    printf '\n\033[31m%s problem(s) found\033[0m\n' "$errors"
    log "verify finished with $errors problem(s)"
    exit 1
fi

date -u +%s > "$VERIFY_DIR/last-ok"

printf '\n\033[32mok\033[0m: every mirror, ref and pinned commit is present and readable\n'
log "verify ok: $total_repos repos, $total_refs refs, $total_pins pinned, sha256:$digest"
