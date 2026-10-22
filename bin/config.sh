# shellcheck shell=bash
# Builds the source plan from /config/config.json plus environment variables.
#
# A "source" is one archived account or one public owner. Every source gets its
# own root directory, its own mirrors, its own ledger.

: "${CONFIG_FILE:=/config/config.json}"
: "${DEFAULT_BRANCH_POLICY:=all}"
: "${BUNDLE_KEEP:=6}"

declare -gA SRC_KIND=()
declare -gA SRC_TOKENS=()
declare -gA SRC_POLICY=()
declare -gA SRC_REPOS=()
declare -gA SRC_DISCOVER=()
SOURCE_NAMES=()
CONFIG_WARNINGS=()

# Split a comma / newline separated list, or a JSON array, into lines.
_split_list() {
    local v=${1:-}
    [ -n "$v" ] || return 0
    if [[ $v == \[* ]]; then
        printf '%s' "$v" | jq -r '.[]?' 2>/dev/null || true
        return 0
    fi
    printf '%s' "$v" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
}

_cfg() { # jq filter, empty output if no config
    [ -r "$CONFIG_FILE" ] || return 0
    jq -r "$1" "$CONFIG_FILE" 2>/dev/null || true
}

_validate_config() {
    [ -r "$CONFIG_FILE" ] || return 0
    jq -e . "$CONFIG_FILE" > /dev/null 2>&1 \
        || die "invalid JSON in $CONFIG_FILE"
}

_touch_source() {
    local name=$1 kind=$2 policy=$3 discover=${4:-0}
    if [ -z "${SRC_KIND[$name]:-}" ]; then
        SOURCE_NAMES+=("$name")
        SRC_KIND[$name]=$kind
        SRC_POLICY[$name]=$policy
        SRC_TOKENS[$name]=""
        SRC_REPOS[$name]=""
        SRC_DISCOVER[$name]=$discover
        return 0
    fi
    if [ "$discover" = "1" ]; then
        SRC_DISCOVER[$name]=1
    fi
    # A public source that an account also covers becomes an account source.
    if [ "$kind" = "account" ] && [ "${SRC_KIND[$name]}" = "public" ]; then
        SRC_KIND[$name]=account
    fi
    # Conflicting policies: prefer the more conservative (keep everything).
    if [ "${SRC_POLICY[$name]}" != "$policy" ]; then
        SRC_POLICY[$name]=all
        CONFIG_WARNINGS+=("$name: conflicting branch policies, using 'all'")
    fi
    return 0
}

_add_token() {
    local name=$1 token=$2
    case " ${SRC_TOKENS[$name]:-} " in
        *" $token "*) ;;
        *) SRC_TOKENS[$name]="${SRC_TOKENS[$name]:-} $token" ;;
    esac
}

_add_repo() {
    local name=$1 repo=$2
    case " ${SRC_REPOS[$name]:-} " in
        *" $repo "*) ;;
        *) SRC_REPOS[$name]="${SRC_REPOS[$name]:-} $repo" ;;
    esac
}

# Map a token to the login it belongs to, persisting the answer so a revoked
# token still points at the archive it already owns.
_resolve_login() {
    local tok=$1 hash name
    hash=$(printf '%s' "$tok" | sha256sum | cut -c1-16)
    if [ -f "$REGISTRY" ]; then
        name=$(awk -F'\t' -v h="$hash" '$1 == h { print $2; exit }' "$REGISTRY")
        if [ -n "${name:-}" ]; then
            printf '%s' "$name"
            return 0
        fi
    fi
    name=$(curl -fsS --retry 2 \
        -H "Authorization: Bearer $tok" \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$API_BASE_URL/user" 2>/dev/null | jq -r '.login // empty' 2>/dev/null || true)
    if [ -z "${name:-}" ]; then
        # Unreachable or revoked: keep a stable, unmistakable name.
        name="token-$hash"
        CONFIG_WARNINGS+=("token ...${hash}: could not resolve a login, using $name")
    fi
    mkdir -p -- "$(dirname -- "$REGISTRY")"
    printf '%s\t%s\n' "$hash" "$name" >> "$REGISTRY"
    printf '%s' "$name"
}

_collect_tokens() { # prints "token<TAB>policy"
    local default_policy=${BRANCH_POLICY:-}
    if [ -z "$default_policy" ]; then
        default_policy=$(_cfg '.defaults.branches // empty' | head -1)
        [ -n "${_:-}" ] || true
    fi
    [ -n "$default_policy" ] || default_policy=$DEFAULT_BRANCH_POLICY

    {
        if [ -r "$CONFIG_FILE" ]; then
            _cfg '.accounts[]? | [.token, (.branches // "")] | @tsv'
        fi
        {
            _split_list "${GITHUB_RO_TOKENS:-}"
            _split_list "${GITHUB_RO_TOKEN:-}"
            if [ -n "${GITHUB_RO_TOKENS_FILE:-}" ] && [ -r "$GITHUB_RO_TOKENS_FILE" ]; then
                tr -d '\r' < "$GITHUB_RO_TOKENS_FILE"
            fi
        } | while read -r t; do
            [ -n "$t" ] && printf '%s\t%s\n' "$t" "$default_policy"
        done
    } | awk -F'\t' 'NF && !seen[$1]++ { p = ($2 == "" ? "'"$default_policy"'" : $2); print $1 "\t" p }'
}

_collect_public() { # prints "kind<TAB>value<TAB>policy"
    local default_policy=${BRANCH_POLICY:-all}
    if [ -r "$CONFIG_FILE" ]; then
        _cfg '.public[]? | (if .repo then "repo" elif .owner then "owner" else empty end)
              + "\t" + (.repo // .owner)
              + "\t" + (.branches // "'"$default_policy"'")'
    fi
    _split_list "${PUBLIC_REPOS:-}" | while read -r r; do
        printf 'repo\t%s\t%s\n' "$r" "$default_policy"
    done
    _split_list "${PUBLIC_ACCOUNTS:-}" | while read -r o; do
        printf 'owner\t%s\t%s\n' "$o" "$default_policy"
    done
}

load_config() {
    _validate_config

    local tok policy kind value owner
    while IFS=$'\t' read -r tok policy; do
        [ -n "$tok" ] || continue
        local name
        name=$(_resolve_login "$tok")
        _touch_source "$name" account "$policy" 1
        _add_token "$name" "$tok"
    done < <(_collect_tokens)

    while IFS=$'\t' read -r kind value policy; do
        [ -n "$value" ] || continue
        case "$kind" in
            owner)
                owner=$value
                _touch_source "$owner" public "$policy" 1
                ;;
            repo)
                owner=${value%%/*}
                if [ "$owner" = "$value" ]; then
                    CONFIG_WARNINGS+=("'$value' is not owner/repo, skipping")
                    continue
                fi
                _touch_source "$owner" public "$policy" 0
                _add_repo "$owner" "$value"
                ;;
        esac
    done < <(_collect_public)

    for w in "${CONFIG_WARNINGS[@]:-}"; do
        [ -n "$w" ] && log "config: $w"
    done

    [ "${#SOURCE_NAMES[@]}" -gt 0 ] \
        || die "nothing configured: set GITHUB_RO_TOKENS, or add accounts/public entries to $CONFIG_FILE"

    return 0
}
