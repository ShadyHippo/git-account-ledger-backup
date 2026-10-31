#!/usr/bin/env bash
# Append-only GitHub archive, multi-source.
#
# Guarantees, per source:
#   * never deletes a local repository, even if the repo or the whole account
#     disappears upstream
#   * never lets a force-push or branch deletion destroy a previous tip
#   * falls back to the known repo list when the API is unavailable, so a
#     transient outage or revoked token does not stop the backup
set -Eeuo pipefail
umask 077

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"
# shellcheck source=config.sh
. "$SELF_DIR/config.sh"

LOG_TAG=backup
LOG_FILE="$LOG_DIR/backup.log"
ensure_dirs
load_config

exec 9>"$ROOT/.lock.mirror"
flock -n 9 || { log "another mirror job holds the lock, skipping"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

declare -A SEEN=()   # owner/repo -> source that owns it, prevents double storage
LOST=0               # mirrors that vanished from disk and had to be rebuilt

# --------------------------------------------------------------- discovery --

_discover_account() { # token
    local token=$1 page=1 out n
    while :; do
        out=$(gh_api "$token" "$API_BASE_URL/user/repos?per_page=100&page=$page&visibility=all&sort=full_name&affiliation=owner,collaborator,organization_member") || return 1
        n=$(jq 'length' <<< "$out")
        if [ "$n" -eq 0 ]; then break; fi
        jq -r '.[] | [.full_name, (.default_branch // "")] | @tsv' <<< "$out"
        if [ "$n" -lt 100 ]; then break; fi
        page=$((page + 1))
    done
}

_discover_owner() { # token(optional), owner
    local token=$1 owner=$2 base page out n url
    for base in users orgs; do
        page=1
        local ok=1
        while :; do
            url="$API_BASE_URL/$base/$owner/repos?per_page=100&page=$page&sort=full_name"
            [ "$base" = "orgs" ] && url="$url&type=all"
            if ! out=$(gh_api "$token" "$url"); then
                ok=0
                break
            fi
            n=$(jq 'length' <<< "$out")
            if [ "$n" -eq 0 ]; then break; fi
            jq -r '.[] | [.full_name, (.default_branch // "")] | @tsv' <<< "$out"
            if [ "$n" -lt 100 ]; then break; fi
            page=$((page + 1))
        done
        [ "$ok" -eq 1 ] && return 0
    done
    return 1
}

# ------------------------------------------------------------------ mirror --

fetch_repo() { # name, dir, default_branch, errfile
    local name=$1 dir=$2 db=$3 err=$4
    local -a specs toks args
    mapfile -t specs < <(build_refspecs "${SRC_POLICY[$name]:-all}" "$db")
    read -r -a toks <<< "$(source_token_list "$name")"

    args=(fetch -q --prune --no-write-fetch-head)
    [ -f "$dir/shallow" ] && args+=(--depth 1)

    if [ "${#toks[@]}" -eq 0 ]; then
        GIT_TERMINAL_PROMPT=0 git -C "$dir" -c credential.helper= \
            "${args[@]}" origin "${specs[@]}" 2> "$err"
        return $?
    fi

    local t
    for t in "${toks[@]}"; do
        if GITHUB_RO_TOKEN="$t" git -C "$dir" -c credential.helper="$SELF_DIR/cred-helper" \
                "${args[@]}" origin "${specs[@]}" 2> "$err"; then
            return 0
        fi
    done
    return 1
}

mirror_repo() { # name, owner/repo, default_branch, allow_retire, api_ok
    local name=$1 full=$2 db=$3 allow_retire=${4:-0} api_ok=${5:-1}
    local dir shallow=0 lost=0 err="$TMP/fetch.err"
    dir=$(mirror_path "$name" "$full")

    if [ ! -d "$dir" ]; then
        if grep -qxF "$full" "$TMP/prev.known" 2>/dev/null; then
            log "CRITICAL mirror was missing from disk, rebuilding from scratch: $name $full (its history and pinned tips are gone)"
            lost=1
            LOST=$((LOST + 1))
        else
            log "creating archive: $name $full"
        fi
        mkdir -p -- "$(dirname -- "$dir")"
        git init -q --bare "$dir"
        git -C "$dir" config remote.origin.url "$GIT_BASE_URL/$full.git"
        git -C "$dir" config gc.auto 0
        git -C "$dir" config gc.pruneExpire never
    fi

    git -C "$dir" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags > "$TMP/before.refs"

    if ! fetch_repo "$name" "$dir" "$db" "$err"; then
        sed 's/^/    /' "$err" >> "$LOG_FILE" 2>/dev/null || true
        if grep -qiE 'not found|does not appear to be a git repository' "$err" 2>/dev/null; then
            # A 404 is ambiguous: the repo may be deleted, or the token may have
            # lost access (GitHub hides 403 as 404). Only retire when we are
            # sure, because retiring is sticky and would freeze the mirror.
            if [ "$allow_retire" = "1" ]; then
                retire_repo "$name" "$full" "no longer visible upstream"
                return 0
            fi
            if [ "$api_ok" = "0" ]; then
                log "unverifiable while the API is unreachable, not retiring: $name $full"
                return 3
            fi
            log "not found but still listed upstream; check the token's access: $name $full"
            return 1
        fi
        log "fetch failed: $name $full"
        return 1
    fi

    if [ -n "${db:-}" ] && git -C "$dir" rev-parse --verify -q "refs/heads/$db" > /dev/null; then
        git -C "$dir" symbolic-ref HEAD "refs/heads/$db"
    else
        # Explicit repos are never discovered, so default_branch may be unknown.
        # A HEAD pointing at a branch that does not exist makes `git clone` of
        # the mirror produce an empty worktree, so resolve it from what is here.
        local cand pick=""
        for cand in main master; do
            if git -C "$dir" rev-parse --verify -q "refs/heads/$cand" > /dev/null; then
                pick=$cand
                break
            fi
        done
        if [ -z "$pick" ]; then
            pick=$(git -C "$dir" for-each-ref --count=1 --format='%(refname:short)' refs/heads)
        fi
        if [ -n "$pick" ]; then
            git -C "$dir" symbolic-ref HEAD "refs/heads/$pick"
        fi
    fi

    [ -f "$dir/shallow" ] && shallow=1

    # LFS objects are not in the pack. Fetch them before pinning so a
    # local-only archive ref is never handed to the LFS API.
    if [ -n "$(git -C "$dir" lfs ls-files --all 2>/dev/null | head -1)" ]; then
        local -a lt
        read -r -a lt <<< "$(source_token_list "$name")"
        local t
        for t in "${lt[@]:-}"; do
            if GITHUB_RO_TOKEN="$t" git -C "$dir" -c credential.helper="$SELF_DIR/cred-helper" \
                    lfs fetch --all origin >> "$LOG_DIR/lfs.log" 2>&1; then
                break
            fi
        done
    fi

    # Pin anything that just became unreachable. A fast-forward needs no pin:
    # the old tip is still an ancestor of the new one. A shallow mirror cannot
    # answer ancestry questions, so it pins on any ref change.
    local sha ref now
    while read -r sha ref; do
        [ -n "${sha:-}" ] || continue
        now=$(git -C "$dir" rev-parse --verify -q "$ref" || true)
        [ "$now" = "$sha" ] && continue
        if [ "$shallow" -eq 0 ] && [ -n "$now" ] \
            && git -C "$dir" merge-base --is-ancestor "$sha" "$now" 2>/dev/null; then
            continue
        fi
        if git -C "$dir" update-ref "refs/archive/$sha" "$sha"; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$name" "$full" "$ref" "$sha" "${now:-DELETED}" \
                >> "$(src_ledger "$name")/pinned.tsv"
            log "pinned orphaned tip: $name $full $ref $sha (was: ${now:-deleted})"
        else
            log "could not pin: $name $full $ref $sha"
        fi
    done < "$TMP/before.refs"

    # Any ref at all means there is something to check; a repo whose only
    # remaining refs are pinned archive tips still deserves a connectivity check.
    if [ -n "$(git -C "$dir" for-each-ref --count=1 --format='%(refname)')" ]; then
        if ! git -C "$dir" fsck --connectivity-only --no-progress --no-dangling > "$TMP/fsck.out" 2>&1; then
            log "fsck reported problems: $name $full"
        fi
        if [ -s "$TMP/fsck.out" ]; then
            printf '%s %s %s\n' "$(ts)" "$name" "$full" >> "$LOG_DIR/fsck.log"
            sed 's/^/    /' "$TMP/fsck.out" >> "$LOG_DIR/fsck.log"
        fi
    fi

    [ "$lost" -eq 1 ] && return 2
    return 0
}

learn_default_branch() { # name, owner/repo -> prints the branch or nothing
    local name=$1 full=$2 t
    t=$(source_token_list "$name" | awk '{print $1}')
    gh_api "$t" "$API_BASE_URL/repos/$full" 2> /dev/null \
        | jq -r '.default_branch // empty' 2> /dev/null || true
}

retire_repo() { # name, owner/repo, reason
    local name=$1 full=$2 reason=$3 f
    f="$(src_state "$name")/retired.tsv"
    touch "$f"
    if ! cut -f2 "$f" | grep -qxF "$full"; then
        printf '%s\t%s\t%s\n' "$(ts)" "$full" "$reason" >> "$f"
        printf '%s\t%s\n' "$(ts)" "$full" >> "$(src_ledger "$name")/vanished.tsv"
        log "retired: $name $full ($reason); mirror kept at $(mirror_path "$name" "$full")"
    fi
}

# ------------------------------------------------------------------ source --

backup_source() {
    local name=$1
    local state ledger
    ensure_source_dirs "$name"
    state="$(src_state "$name")"

    local disc="$TMP/$name.discovery"
    : > "$disc"
    local attempted=0 discovered=0

    if [ "${SRC_DISCOVER[$name]:-0}" = "1" ]; then
        attempted=1
        local t
        if [ "${SRC_KIND[$name]}" = "account" ]; then
            for t in $(source_token_list "$name"); do
                if _discover_account "$t" > "$disc"; then discovered=1; break; fi
            done
        else
            t=$(source_token_list "$name" | awk '{print $1}')
            if _discover_owner "$t" "$name" > "$disc"; then discovered=1; fi
        fi
    else
        discovered=1   # explicit repo list, nothing to discover
    fi

    # Explicit repos always belong to the source, discovered or not.
    local r
    for r in ${SRC_REPOS[$name]:-}; do
        printf '%s\t\n' "$r" >> "$disc"
    done

    # What is visible upstream right now. Used to decide whether a 404 means
    # "deleted" (retire) or "the token cannot see it any more" (do not retire).
    cp -f "$disc" "$TMP/$name.fresh"

    if [ "$attempted" -eq 1 ] && [ "$discovered" -eq 0 ]; then
        printf 'unreachable\n' > "$state/state"
        warn "$name: discovery failed, falling back to the known repo list"
    else
        printf 'ok\n' > "$state/state"
    fi

    # Remember what we already had, for loss detection inside the loop.
    : > "$TMP/prev.known"
    [ -f "$state/repos.known" ] && cp -f "$state/repos.known" "$TMP/prev.known"

    # Union with everything we already knew: nothing leaves the archive because
    # it stopped being visible.
    if [ -s "$state/repos.tsv" ]; then
        cut -f1 "$state/repos.tsv" | while read -r r; do
            [ -n "$r" ] && printf '%s\t\n' "$r"
        done >> "$disc"
    fi

    if [ ! -s "$disc" ]; then
        # A reachable account with no repositories is a valid state, not a
        # failure. A failed discovery with nothing known is also not a failure
        # to shout about here; the source is already marked unreachable.
        log "$name: no repositories to archive"
        date -u +%s > "$state/last-backup-ok"
        return 0
    fi

    awk -F'\t' 'NF { if ($2 != "") db[$1] = $2; else if (!($1 in db)) db[$1] = "" }
        END { for (r in db) print r "\t" db[r] }' "$disc" | sort > "$TMP/$name.final"

    cut -f1 "$TMP/$name.final" > "$state/repos.known"

    local total=0 ok=0 failed=0 skipped=0 unverifiable=0 full db rc
    local api_ok=1
    : > "$TMP/$name.learned"
    if [ "$attempted" -eq 1 ] && [ "$discovered" -eq 0 ]; then
        api_ok=0
    fi

    while IFS=$'\t' read -r full db; do
        [ -n "$full" ] || continue
        total=$((total + 1))

        if [ -f "$state/retired.tsv" ] && cut -f2 "$state/retired.tsv" | grep -qxF "$full"; then
            skipped=$((skipped + 1))
            continue
        fi
        if [ -n "${SEEN[$full]:-}" ]; then
            skipped=$((skipped + 1))
            continue
        fi
        SEEN[$full]=$name

        # Retiring is permanent, so only allow it when the repo is genuinely
        # absent from a successful discovery, or was named explicitly.
        local allow_retire=0
        if ! cut -f1 "$TMP/$name.fresh" | grep -qxF "$full"; then
            allow_retire=1
        fi
        case " ${SRC_REPOS[$name]:-} " in
            *" $full "*) allow_retire=1 ;;
        esac

        # Explicit repos are never discovered, so their default branch has to be
        # asked for once. Learned values persist in repos.tsv.
        if [ -z "${db:-}" ] && [ "$api_ok" -eq 1 ]; then
            db=$(learn_default_branch "$name" "$full")
            if [ -n "$db" ]; then
                printf '%s\t%s\n' "$full" "$db" >> "$TMP/$name.learned"
            fi
        fi

        rc=0
        mirror_repo "$name" "$full" "$db" "$allow_retire" "$api_ok" || rc=$?
        case "$rc" in
            0) ok=$((ok + 1)) ;;
            3) unverifiable=$((unverifiable + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done < "$TMP/$name.final"

    cat "$TMP/$name.final" "$TMP/$name.learned" \
        | awk -F'\t' 'NF { if ($2 != "") db[$1] = $2; else if (!($1 in db)) db[$1] = "" }
            END { for (r in db) print r "\t" db[r] }' | sort > "$state/repos.tsv"

    # Integrity: anything we believe we hold that is not on disk, and that was
    # not rebuilt above (retired repos are skipped), is an incident.
    local missing=0
    while read -r full; do
        [ -n "$full" ] || continue
        if [ ! -d "$(mirror_path "$name" "$full")" ]; then
            log "CRITICAL mirror missing from disk: $name $full"
            missing=$((missing + 1))
        fi
    done < "$state/repos.known"

    log "$name: $ok ok, $failed failed, $unverifiable unverifiable, $skipped skipped, $total known, $missing missing"

    if [ "$failed" -eq 0 ] && [ "$missing" -eq 0 ]; then
        date -u +%s > "$state/last-backup-ok"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------- drive --

overall=0
sources_ok=0
for name in "${SOURCE_NAMES[@]}"; do
    if backup_source "$name"; then
        sources_ok=$((sources_ok + 1))
    else
        overall=1
    fi
done

log "run finished: $sources_ok/${#SOURCE_NAMES[@]} sources clean, $LOST mirror(s) rebuilt from scratch"

if [ "$overall" -eq 0 ]; then
    date -u +%s > "$STATUS_DIR/last-backup-ok"
else
    exit 1
fi
