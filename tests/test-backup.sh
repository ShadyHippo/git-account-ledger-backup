#!/usr/bin/env bash
# End-to-end test of the v2 guarantees against local bare repos.
# No network, no Docker: the API is faked, git talks to file:// origins.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export ROOT="$tmp/data"
export GIT_BASE_URL="file://$tmp/origins"
export CONFIG_FILE="$tmp/config.json"
export FAKE_ROOT="$tmp/api"
export PATH="$here/tests/fakebin:$PATH"
unset GITHUB_RO_TOKEN GITHUB_RO_TOKENS GITHUB_RO_TOKENS_FILE PUBLIC_REPOS PUBLIC_ACCOUNTS BRANCH_POLICY || true

mkdir -p "$FAKE_ROOT" "$tmp/work"

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if ( set +o pipefail; eval "$2" ) > /dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

mkjson() { # owner/repo...
    local out='[' first=1 r
    for r in "$@"; do
        [ "$first" -eq 1 ] || out+=','
        first=0
        out+="{\"full_name\":\"$r\",\"default_branch\":\"main\"}"
    done
    printf '%s]' "$out"
}

origin() { # owner/repo -> workdir path
    local full=$1 d w
    d="$tmp/origins/$full.git"
    w="$tmp/work/$(printf '%s' "$full" | tr '/' '_')"
    mkdir -p "$(dirname "$d")"
    git init -q --bare -b main "$d"
    git init -q -b main "$w"
    git -C "$w" config user.name test
    git -C "$w" config user.email test@example.com
    git -C "$w" config commit.gpgsign false
    git -C "$w" remote add origin "$d"
    printf '%s' "$w"
}

commit() { # workdir, message
    git -C "$1" add -A
    git -C "$1" commit -qm "$2"
    git -C "$1" rev-parse HEAD
}

echo "== seeding origins and fake API"
w=$(origin alpha/repo-one)
echo one > "$w/f"
sha_a=$(commit "$w" A)
git -C "$w" push -q origin main
echo two >> "$w/f"
sha_b=$(commit "$w" B)
git -C "$w" push -q origin main
git -C "$w" checkout -qb feature
echo three > "$w/g"
sha_d=$(commit "$w" D)
git -C "$w" push -q origin feature
git -C "$w" checkout -q main

w=$(origin shared/repo-x)
echo x > "$w/x"
commit "$w" X > /dev/null
git -C "$w" push -q origin main

w=$(origin beta/repo-two)
echo b > "$w/b"
commit "$w" B > /dev/null
git -C "$w" push -q origin main
git -C "$w" checkout -qb feature
echo bf > "$w/bf"
commit "$w" BF > /dev/null
git -C "$w" push -q origin feature
git -C "$w" checkout -q main

w=$(origin artcraft/art)
echo art > "$w/a"
commit "$w" BASE > /dev/null
git -C "$w" push -q origin main
git -C "$w" checkout -qb release/1.0
echo rel > "$w/r"
commit "$w" REL > /dev/null
git -C "$w" push -q origin release/1.0
git -C "$w" checkout -q main
git -C "$w" checkout -qb dev/experiment
echo dev > "$w/d"
commit "$w" DEV > /dev/null
git -C "$w" push -q origin dev/experiment
git -C "$w" checkout -q main

printf '{"login":"alpha"}' > "$FAKE_ROOT/user_tok-alpha.json"
printf '{"login":"beta"}'  > "$FAKE_ROOT/user_tok-beta.json"
mkjson alpha/repo-one shared/repo-x > "$FAKE_ROOT/userrepos_tok-alpha.json"
mkjson beta/repo-two > "$FAKE_ROOT/userrepos_tok-beta.json"
mkjson artcraft/art > "$FAKE_ROOT/owner_artcraft.json"

cat > "$CONFIG_FILE" <<'JSON'
{
  "accounts": [
    {"token": "tok-alpha", "branches": "all"},
    {"token": "tok-beta",  "branches": "default"}
  ],
  "public": [
    {"repo": "artcraft/art", "branches": "main,release/*"}
  ]
}
JSON

A="$ROOT/sources/alpha/mirrors/alpha/repo-one.git"
X="$ROOT/sources/alpha/mirrors/shared/repo-x.git"
B="$ROOT/sources/beta/mirrors/beta/repo-two.git"
C="$ROOT/sources/artcraft/mirrors/artcraft/art.git"

echo "== one directory per account"
check "backup exits 0"              "\"$here/bin/backup.sh\""
check "alpha source created"        "[ -d '$ROOT/sources/alpha' ]"
check "beta source created"         "[ -d '$ROOT/sources/beta' ]"
check "public source created"       "[ -d '$ROOT/sources/artcraft' ]"
check "alpha repo mirrored"         "[ -d '$A' ]"
check "collaborator repo mirrored"  "[ -d '$X' ]"
check "beta repo mirrored"          "[ -d '$B' ]"
check "public repo mirrored"        "[ -d '$C' ]"
check "fsck log is clean"           "[ ! -s '$ROOT/log/fsck.log' ]"

echo "== branch policy: all / default / explicit glob"
check "alpha tracks feature"        "git -C '$A' rev-parse -q --verify refs/heads/feature"
check "beta ignores feature (default)" "! git -C '$B' rev-parse -q --verify refs/heads/feature"
check "beta tracks main"            "git -C '$B' rev-parse -q --verify refs/heads/main"
check "public tracks main"          "git -C '$C' rev-parse -q --verify refs/heads/main"
check "public tracks release/1.0"   "git -C '$C' rev-parse -q --verify refs/heads/release/1.0"
check "public ignores dev/experiment" "! git -C '$C' rev-parse -q --verify refs/heads/dev/experiment"

echo "== force-push must not destroy the old tip"
git -C "$tmp/work/alpha_repo-one" push -q -f origin "$sha_a:main"
check "backup exits 0"              "\"$here/bin/backup.sh\""
check "main rolled back"            "[ \"\$(git -C '$A' rev-parse refs/heads/main)\" = '$sha_a' ]"
check "old tip pinned"              "[ \"\$(git -C '$A' rev-parse refs/archive/$sha_b)\" = '$sha_b' ]"
check "pin recorded per source"     "grep -q '$sha_b' '$ROOT/sources/alpha/ledger/pinned.tsv'"
check "aggressive gc keeps pin"     "git -C '$A' gc --prune=now -q && git -C '$A' cat-file -e '$sha_b'"

echo "== a 404 that is still listed upstream is a permission problem, not a deletion"
rm -rf "$tmp/origins/beta/repo-two.git"
check "backup reports failure"      "! \"$here/bin/backup.sh\""
check "NOT retired"                 "[ ! -s '$ROOT/sources/beta/state/retired.tsv' ]"
check "mirror kept"                 "[ -d '$B' ]"

echo "== a repo that disappears from the account is retired, never deleted"
mkjson > "$FAKE_ROOT/userrepos_tok-beta.json"
check "backup exits 0"              "\"$here/bin/backup.sh\""
check "retired recorded"            "grep -q 'beta/repo-two' '$ROOT/sources/beta/state/retired.tsv'"
check "beta mirror kept"            "[ -d '$B' ]"
check "still in repos.known"        "grep -qxF 'beta/repo-two' '$ROOT/sources/beta/state/repos.known'"
"$here/bin/backup.sh" > /dev/null 2>&1 || true
check "retired repos are skipped on the next run" \
    "tail -8 '$ROOT/log/backup.log' | grep -q '1 skipped'"

echo "== API outage falls back to the known repo list"
out=$(FAKE_API_FAIL=1 "$here/bin/backup.sh" 2>&1) && rc=0 || rc=$?
check "backup still succeeds"       "[ '$rc' -eq 0 ]"
check "source marked unreachable"   "[ \"\$(cat '$ROOT/sources/beta/state/state')\" = unreachable ]"
check "alpha mirror untouched"      "[ -d '$A' ]"
check "public mirror untouched"     "[ -d '$C' ]"

echo "== ledger records each event once, per source"
cat > "$FAKE_ROOT/events_alpha_repo-one.json" <<'JSON'
[
 {"id":"1001","type":"PushEvent","created_at":"2026-01-01T00:00:00Z",
  "actor":{"login":"agent"},"payload":{"ref":"refs/heads/main","before":"aaa","after":"bbb","forced":true}},
 {"id":"1002","type":"WatchEvent","created_at":"2026-01-01T00:00:01Z",
  "actor":{"login":"someone"},"payload":{}}
]
JSON
check "ledger exits 0"              "\"$here/bin/ledger.sh\""
check "ledger exits 0 again"        "\"$here/bin/ledger.sh\""
check "only PushEvent kept"         "[ \"\$(wc -l < '$ROOT/sources/alpha/ledger/events.jsonl')\" = 1 ]"
check "before-sha captured"         "grep -q '\"before\":\"aaa\"' '$ROOT/sources/alpha/ledger/events.jsonl'"

echo "== snapshot --mode archive keeps history, drops pinned tips"
w="$tmp/work/alpha_repo-one"
echo five > "$w/i"
git -C "$w" add i
git -C "$w" commit -qm E
git -C "$w" push -q origin main
"$here/bin/backup.sh" > /dev/null 2>&1 || true
check "main has real history"       "[ \"\$(git -C '$A' rev-list --count refs/heads/main)\" -ge 2 ]"
check "archive snapshot exits 0"    "\"$here/bin/snapshot.sh\" repo alpha alpha/repo-one --mode archive --yes"
check "no archive refs left"        "[ -z \"\$(git -C '$A' for-each-ref refs/archive)\" ]"
check "branch history intact"       "[ \"\$(git -C '$A' rev-list --count refs/heads/main)\" -ge 2 ]"
check "boundary recorded"           "grep -q 'alpha/repo-one' '$ROOT/sources/alpha/ledger/snapshots.tsv'"
check "pre-snapshot bundle exists"  "find '$ROOT/bundles/alpha/snapshots' -name 'repo-one.bundle' | grep -q ."
check "pre-snapshot bundle verifies" "git -C '$A' bundle verify -q \"\$(find '$ROOT/bundles/alpha/snapshots' -name 'repo-one.bundle' | head -1)\""

echo "== snapshot --mode tip keeps the tip SHA and the ledger continuity"
# give main somewhere to collapse from
w="$tmp/work/alpha_repo-one"
echo four > "$w/h"
git -C "$w" add h
git -C "$w" commit -qm C
git -C "$w" push -q origin main
"$here/bin/backup.sh" > /dev/null 2>&1 || true
check "main has real history"       "[ \"\$(git -C '$A' rev-list --count refs/heads/main)\" -ge 2 ]"
tip_before=$(git -C "$A" rev-parse refs/heads/main)
check "tip snapshot exits 0"        "\"$here/bin/snapshot.sh\" repo alpha alpha/repo-one --mode tip --yes"
check "mirror is now shallow"       "[ -f '$A/shallow' ]"
check "tip SHA unchanged"           "[ \"\$(git -C '$A' rev-parse refs/heads/main)\" = '$tip_before' ]"
check "history collapsed to one"    "[ \"\$(git -C '$A' rev-list --count refs/heads/main)\" = 1 ]"
check "snapshot logged with sizes"  "awk -F'\t' '\$4==\"tip\" && \$5>0' '$ROOT/sources/alpha/ledger/snapshots.tsv' | grep -q ."

echo "== recovery tooling"
check "restore list finds repo"     "\"$here/bin/restore.sh\" list | grep -q 'alpha/repo-one'"
check "restore clone works"         "\"$here/bin/restore.sh\" clone alpha/repo-one '$tmp/cloned'"
check "cloned worktree has files"   "[ -f '$tmp/cloned/f' ]"
check "pinned listing runs"         "\"$here/bin/restore.sh\" pinned alpha/repo-one"
check "snapshot list runs"          "\"$here/bin/snapshot.sh\" list alpha | grep -q 'alpha/repo-one'"
check "stats runs"                  "\"$here/bin/stats.sh\" | grep -q everything"
check "healthcheck runs"            "\"$here/bin/healthcheck.sh\" | grep -q sources"

echo "== config: JSON array of tokens in the environment"
names=$(ROOT="$tmp/envonly" GITHUB_RO_TOKENS='["tok-alpha","tok-beta"]' CONFIG_FILE=/nonexistent \
    bash -c ". '$here/bin/common.sh'; . '$here/bin/config.sh'; load_config; printf '%s\n' \"\${SOURCE_NAMES[@]}\"" 2>/dev/null | sort | tr '\n' ' ')
check "env token array resolves both accounts" "[ '$names' = 'alpha beta ' ]"

echo "== nightly scheduler arithmetic"
sched() { bash -c ". '$here/bin/schedule.sh'; $1"; }
for t in 00:00 03:15 12:00 23:59; do
    d=$(sched "seconds_until $t")
    check "seconds_until $t is within a day" "[ '$d' -gt 0 ] && [ '$d' -le 86400 ]"
done
check "SCHEDULE_AT rejects 24:00"   "! sched 'valid_hhmm 24:00'"
check "SCHEDULE_AT rejects 3:15"    "! sched 'valid_hhmm 3:15'"
check "SCHEDULE_AT accepts 03:15"   "sched 'valid_hhmm 03:15'"
check "nanosecond-free HH:MM math"  "[ \"\$(sched 'seconds_until 00:00')\" -le 86400 ]"

echo "== bundles survive an empty repo and a first run with nothing to prune"
check "bundle run exits 0"          "BUNDLE_INTERVAL=0 \"$here/bin/bundle.sh\""
check "no bundle for the empty repo" "[ ! -e \"\$(find '$ROOT/bundles/alpha' -name 'repo-two.bundle' 2>/dev/null | head -1)\" ]"
check "bundle for the real repo"    "find '$ROOT/bundles/alpha' -name 'repo-one.bundle' | grep -q ."

echo "== an account with no repositories is not a failure"
printf '[]' > "$FAKE_ROOT/owner_emptysrc.json"
out=$(PUBLIC_ACCOUNTS=emptysrc "$here/bin/backup.sh" 2>&1) && rc=0 || rc=$?
check "empty account exits 0"       "[ '$rc' -eq 0 ]"
check "empty account logged"        "printf '%s' \"\$out\" | grep -q 'no repositories to archive'"
check "source dir created"          "[ -d '$ROOT/sources/emptysrc' ]"

echo "== notification hooks"
export FAKE_NOTIFY_LOG="$tmp/notify.log"
: > "$FAKE_NOTIFY_LOG"
NTFY_URL=https://ntfy.test NTFY_TOPIC=backups "$here/bin/notify.sh" alert "t" "b" || true
check "ntfy alert sent"             "grep -q 'https://ntfy.test/backups' '$FAKE_NOTIFY_LOG'"
ALERT_URL=https://hook.test/post "$here/bin/notify.sh" alert "t" "b" || true
check "generic webhook sent"        "grep -q 'https://hook.test/post' '$FAKE_NOTIFY_LOG'"
HEARTBEAT_URL=https://hc.test/ping/abc "$here/bin/notify.sh" heartbeat ok || true
check "heartbeat ping sent"         "grep -q 'https://hc.test/ping/abc' '$FAKE_NOTIFY_LOG'"
HEARTBEAT_URL=https://hc.test/ping/abc "$here/bin/notify.sh" heartbeat fail || true
check "heartbeat fail sent"         "grep -q 'https://hc.test/ping/abc/fail' '$FAKE_NOTIFY_LOG'"
: > "$FAKE_NOTIFY_LOG"
"$here/bin/notify.sh" alert "t" "b" 2>/dev/null || true
check "no-op without config"        "[ ! -s '$FAKE_NOTIFY_LOG' ]"

echo "== a failing pass reports itself and exits non-zero"
: > "$FAKE_NOTIFY_LOG"
NTFY_URL=https://ntfy.test NTFY_TOPIC=backups ONE_PASS=1 ROOT="$tmp/empty-root" CONFIG_FILE=/nonexistent \
    "$here/bin/entrypoint.sh" loop > /dev/null 2>&1 && rc=0 || rc=$?
check "ONE_PASS propagates failure" "[ '$rc' -ne 0 ]"
check "failure alert delivered"     "grep -q 'https://ntfy.test/backups' '$FAKE_NOTIFY_LOG'"

echo "== verify works against a read-only archive"
"$here/bin/verify.sh" > /dev/null 2>&1 || true
before=$(wc -l < "$ROOT/verify/history.tsv" 2>/dev/null || echo 0)
check "verify --no-write passes"    "\"$here/bin/verify.sh\" --no-write"
after=$(wc -l < "$ROOT/verify/history.tsv" 2>/dev/null || echo 0)
check "no attestation written"      "[ '$before' -eq '$after' ]"

echo "== a mirror deleted out from under us is reported"
rm -rf "$X"
out=$("$here/bin/backup.sh" 2>&1) && rc=0 || rc=$?
check "backup fails loudly"         "[ '$rc' -ne 0 ]"
check "CRITICAL logged"             "printf '%s' \"\$out\" | grep -q 'CRITICAL mirror'"

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m%s checks passed\033[0m\n' "$pass"
else
    printf '\033[31m%s passed, %s FAILED\033[0m\n' "$pass" "$fail"
    exit 1
fi
