#!/usr/bin/env bash
# Append-only GitHub archive.
#
# Guarantees:
#   * never deletes a local repository, even if it disappears upstream
#   * never lets a force-push or branch deletion destroy the previous tips
#   * aborts without side effects if discovery fails
set -Eeuo pipefail
umask 077

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"

LOG_TAG=backup
LOG_FILE="$LOG_DIR/backup.log"
ensure_dirs

TOKEN=$(read_token) || die "no token: set GITHUB_RO_TOKEN or mount GITHUB_RO_TOKEN_FILE"
[ -n "$TOKEN" ] || die "token is empty"
export TOKEN
export GITHUB_RO_TOKEN="$TOKEN"

exec 9>"$ROOT/.lock.mirror"
flock -n 9 || { log "another mirror job holds the lock, skipping"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

GIT_OPTS=(-c credential.helper="$SELF_DIR/cred-helper")

# ---------------------------------------------------------------- discovery --
: > "$TMP/repos.tsv"
page=1
while :; do
    if ! out=$(api_get "$API_BASE_URL/user/repos?per_page=100&page=$page&visibility=all&sort=full_name&affiliation=owner,collaborator,organization_member"); then
        die "repository discovery failed on page $page; aborting without touching anything"
    fi
    n=$(jq 'length' <<< "$out")
    if [ "$n" -eq 0 ]; then
        break
    fi
    jq -r '.[] | [.full_name, (.archived | tostring)] | @tsv' <<< "$out" >> "$TMP/repos.tsv"
    if [ "$n" -lt 100 ]; then
        break
    fi
    page=$((page + 1))
done

sort -o "$TMP/repos.tsv" "$TMP/repos.tsv"
[ -s "$TMP/repos.tsv" ] || die "discovery returned zero repositories; refusing to continue"

cut -f1 "$TMP/repos.tsv" > "$TMP/seen.txt"

# A repo vanishing upstream must never delete anything locally. Record it.
if [ -s "$ROOT/repos.known" ]; then
    while read -r gone; do
        log "no longer visible upstream, mirror kept: $gone"
        printf '%s\t%s\n' "$(ts)" "$gone" >> "$LEDGER_DIR/vanished.tsv"
    done < <(comm -23 <(sort -u "$ROOT/repos.known") "$TMP/seen.txt")
fi
cp -f "$TMP/seen.txt" "$ROOT/repos.known"

# ------------------------------------------------------------------- mirror --
ok=0
failed=0

while IFS=$'\t' read -r full _archived; do
    [ -n "$full" ] || continue
    dir="$MIRRORS/$full.git"
    url="$GIT_BASE_URL/$full.git"

    if [ ! -d "$dir" ]; then
        log "creating mirror: $full"
        mkdir -p -- "$(dirname -- "$dir")"
        git init -q --bare "$dir"
        git -C "$dir" config remote.origin.url "$url"
        git -C "$dir" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
        git -C "$dir" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
        # We repack on our own schedule, and we never prune implicitly.
        git -C "$dir" config gc.auto 0
        git -C "$dir" config gc.pruneExpire never
    fi

    git -C "$dir" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags > "$TMP/before.txt"

    # Explicit refspecs only. `clone --mirror` / `remote update` use
    # +refs/*:refs/* and would prune refs/archive/* along with the branches.
    if ! git -C "$dir" "${GIT_OPTS[@]}" fetch --prune --no-write-fetch-head origin \
            >> "$TMP/fetch.out" 2>> "$LOG_FILE"; then
        log "fetch failed: $full"
        failed=$((failed + 1))
        continue
    fi

    # LFS objects are not in the pack, and --mirror silently omits them.
    # Run before pinning so a local-only archive ref is never sent to the API.
    if [ -n "$(git -C "$dir" lfs ls-files --all 2>/dev/null | head -1)" ]; then
        if ! git -C "$dir" "${GIT_OPTS[@]}" lfs fetch --all origin >> "$LOG_DIR/lfs.log" 2>&1; then
            log "lfs fetch failed: $full"
        fi
    fi

    # Pin anything that just became unreachable. Fast-forwards need no pin:
    # the old tip is still an ancestor of the new one, so it stays reachable.
    while read -r sha ref; do
        [ -n "${sha:-}" ] || continue
        now=$(git -C "$dir" rev-parse --verify -q "$ref" || true)
        if [ "$now" = "$sha" ]; then
            continue
        fi
        if [ -n "$now" ] && git -C "$dir" merge-base --is-ancestor "$sha" "$now" 2>/dev/null; then
            continue
        fi
        if git -C "$dir" update-ref "refs/archive/$sha" "$sha"; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$full" "$ref" "$sha" "${now:-DELETED}" \
                >> "$LEDGER_DIR/pinned.tsv"
            log "pinned orphaned tip: $full $ref $sha (was: ${now:-deleted})"
        else
            log "could not pin: $full $ref $sha"
        fi
    done < "$TMP/before.txt"

    git -C "$dir" fsck --connectivity-only -q 2>> "$LOG_DIR/fsck.log" \
        || log "fsck reported problems: $full"

    ok=$((ok + 1))
done < "$TMP/repos.tsv"

log "run finished: $ok ok, $failed failed, $(wc -l < "$TMP/repos.tsv") repos visible"

if [ "$failed" -eq 0 ]; then
    date -u +%s > "$STATUS_DIR/last-backup-ok"
else
    exit 1
fi
