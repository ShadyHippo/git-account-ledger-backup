#!/usr/bin/env bash
# Deliberately destructive space reclaim. Manual only, never scheduled.
#
#   --mode archive   Drop refs/archive/* (the pinned force-push history) and
#                    repack. Full branch history is kept. Conservative.
#
#   --mode tip       Replace the mirror with a depth-1 shallow clone. Keeps the
#                    tip commit SHA of every tracked branch, so the ledger stays
#                    continuous, but the history before it is gone. Aggressive.
#
# Both modes first write and verify a bundle unless --no-bundle, so the state
# you are about to discard always exists somewhere.
set -Eeuo pipefail
umask 077

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SELF_DIR/common.sh"
# shellcheck source=config.sh
. "$SELF_DIR/config.sh"

LOG_TAG=snapshot
LOG_FILE="$LOG_DIR/snapshot.log"
ensure_dirs

usage() {
    cat <<'EOF'
usage: snapshot.sh <command> [options]

  list [source]                      repos with size, pinned tips, shallow flag
  repo <source> <owner/repo> [...]   snapshot one repository
  source <source> [...]              snapshot every repository in a source

options:
  --mode tip|archive   what to discard (default: archive)
  --no-bundle          skip the pre-snapshot bundle (you lose the escape hatch)
  --yes                actually do it; without this, only prints the plan

examples:
  snapshot.sh list alpha
  snapshot.sh repo alpha alpha/repo-one --mode archive --yes
  snapshot.sh source artcraft --mode tip --yes
EOF
}

size_kb() { du -sk "$1" 2>/dev/null | cut -f1 || echo 0; }

keep_branch() { # branch, policy, default_branch
    local b=$1 p=$2 db=${3:-} pat
    case "$p" in
        all) return 0 ;;
        default) [ "$b" = "$db" ] ;;
        *)
            local IFS=,
            for pat in $p; do
                [ -n "$pat" ] || continue
                # shellcheck disable=SC2053
                [[ $b == $pat ]] && return 0
            done
            return 1
            ;;
    esac
}

_bundle_first() { # source, repo -> path
    local name=$1 full=$2 dir stamp out
    dir=$(mirror_path "$name" "$full")
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    out="$(src_bundles "$name")/snapshots/$stamp/$full.bundle"
    mkdir -p -- "$(dirname -- "$out")"
    git -C "$dir" bundle create -q "$out" --all || return 1
    git -C "$dir" bundle verify -q "$out" > /dev/null 2>&1 || return 1
    log "$name $full: pre-snapshot bundle verified at $out"
    printf '%s' "$out"
}

snapshot_repo() { # source, repo, mode, do_bundle, confirm
    local name=$1 full=$2 mode=$3 do_bundle=$4 confirm=$5
    local dir before after result
    dir=$(mirror_path "$name" "$full")

    [ -d "$dir" ] || die "no mirror for $name $full"
    before=$(size_kb "$dir")

    if [ "$confirm" != "1" ]; then
        printf 'would shrink %s %s (%s) with --mode %s\n' \
            "$name" "$full" "$(human $((before * 1024)))" "$mode"
        return 2
    fi

    if [ "$do_bundle" = "1" ]; then
        _bundle_first "$name" "$full" > /dev/null || die "pre-snapshot bundle failed; refusing to touch $full"
    fi

    case "$mode" in
        archive)
            local n
            n=$(git -C "$dir" for-each-ref --format='%(refname)' refs/archive | wc -l)
            git -C "$dir" for-each-ref --format='%(refname)' refs/archive \
                | while read -r r; do git -C "$dir" update-ref -d "$r"; done
            git -C "$dir" repack -adq
            git -C "$dir" prune --expire=now > /dev/null 2>&1 || true
            log "$name $full: dropped $n pinned tips"
            ;;
        tip)
            local policy db remote tmp
            policy=${SRC_POLICY[$name]:-all}
            db=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || true)
            remote=$(git -C "$dir" config remote.origin.url)
            tmp="$dir.new.$$"
            rm -rf -- "$tmp"

            local -a cargs=(clone -q --bare --depth 1)
            if [ "$policy" = "default" ] && [ -n "$db" ]; then
                cargs+=(--single-branch --branch "$db")
            else
                cargs+=(--no-single-branch)
            fi

            local tok
            tok=$(source_token_list "$name" | awk '{print $1}')
            log "$name $full: shallow clone with policy '$policy'"
            if [ -n "$tok" ]; then
                GITHUB_RO_TOKEN="$tok" git -c credential.helper="$SELF_DIR/cred-helper" \
                    "${cargs[@]}" "$remote" "$tmp" || die "shallow clone failed for $full"
            else
                GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
                    "${cargs[@]}" "$remote" "$tmp" || die "shallow clone failed for $full"
            fi

            git -C "$tmp" config gc.auto 0
            git -C "$tmp" config gc.pruneExpire never

            # Trim branches the policy does not cover (clone has no glob support).
            if [ "$policy" != "all" ]; then
                git -C "$tmp" for-each-ref --format='%(refname:short)' refs/heads \
                    | while read -r b; do
                        keep_branch "$b" "$policy" "$db" || git -C "$tmp" update-ref -d "refs/heads/$b"
                    done
                git -C "$tmp" gc --prune=now -q
            fi

            local tips
            tips=$(git -C "$dir" for-each-ref --format='%(refname)=%(objectname)' refs/heads | paste -sd, -)
            log "$name $full: replacing; previous tips: $tips"

            mv -- "$dir" "$dir.pre-snapshot"
            mv -- "$tmp" "$dir"
            rm -rf -- "$dir.pre-snapshot"
            log "$name $full: replaced with tip-only snapshot"
            ;;
        *)
            die "unknown mode: $mode"
            ;;
    esac

    after=$(size_kb "$dir")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(ts)" "$name" "$full" "$mode" \
        "$before" "$after" \
        "$(git -C "$dir" for-each-ref --format='%(refname)=%(objectname)' refs/heads | paste -sd, -)" \
        >> "$(src_ledger "$name")/snapshots.tsv"

    log "$name $full: $mode snapshot done, $(human $((before * 1024))) -> $(human $((after * 1024)))"
    return 0
}

list_source() { # source
    local name=$1 state f full dir kb pinned shallow
    state="$(src_state "$name")"
    [ -s "$state/repos.tsv" ] || { echo "no repos for $name"; return 0; }
    printf '%-40s %10s %8s %6s %s\n' REPO SIZE PINNED SHALLOW DEFAULT
    while IFS=$'\t' read -r full db; do
        [ -n "$full" ] || continue
        dir=$(mirror_path "$name" "$full")
        [ -d "$dir" ] || { printf '%-40s %10s %8s %6s %s\n' "$full" MISSING - - "$db"; continue; }
        kb=$(size_kb "$dir")
        pinned=$(git -C "$dir" for-each-ref --format=x refs/archive | wc -l)
        shallow=no
        [ -f "$dir/shallow" ] && shallow=yes
        printf '%-40s %10s %8s %6s %s\n' "$full" "$(human $((kb * 1024)))" "$pinned" "$shallow" "$db"
    done < "$state/repos.tsv"
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case "$cmd" in
    list)
        name=${1:-}
        if [ -n "$name" ]; then
            list_source "$name"
        else
            [ -d "$SOURCES_DIR" ] || die "no sources yet"
            for d in "$SOURCES_DIR"/*/; do
                [ -d "$d" ] || continue
                echo "== $(basename "$d")"
                list_source "$(basename "$d")"
            done
        fi
        ;;

    repo|source)
        mode=archive
        do_bundle=1
        confirm=0
        if [ "$cmd" = "repo" ]; then
            src=${1:?source required}; shift
            full=${1:?owner/repo required}; shift
        else
            name=${1:?source required}; shift
        fi
        while [ $# -gt 0 ]; do
            case "$1" in
                --mode) mode=${2:?}; shift 2 ;;
                --no-bundle) do_bundle=0; shift ;;
                --yes) confirm=1; shift ;;
                *) die "unknown option: $1" ;;
            esac
        done

        load_config

        if [ "$cmd" = "repo" ]; then
            snapshot_repo "$src" "$full" "$mode" "$do_bundle" "$confirm"
        else
            state="$(src_state "$name")"
            [ -s "$state/repos.tsv" ] || die "no repos known for source $name"
            rc=0
            while IFS=$'\t' read -r full _db; do
                [ -n "$full" ] || continue
                snapshot_repo "$name" "$full" "$mode" "$do_bundle" "$confirm" || {
                    r=$?
                    [ "$r" -eq 2 ] || rc=1
                }
            done < "$state/repos.tsv"
            exit "$rc"
        fi
        ;;

    ""|-h|--help|help)
        usage
        ;;
    *)
        usage
        exit 2
        ;;
esac
