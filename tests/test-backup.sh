#!/usr/bin/env bash
# End-to-end test of the append-only guarantees against local bare repos.
# No network, no Docker: the API is faked, git talks to file:// origins.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export ROOT="$tmp/data"
export GIT_BASE_URL="file://$tmp/origins"
export GITHUB_RO_TOKEN="dummy-token"
export FAKE_REPOS_JSON="$tmp/repos.json"
export PATH="$here/tests/fakebin:$PATH"

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2" > /dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

json_repos() { # $1: extra object or empty
    printf '[{"full_name":"alice/repo-one","archived":false}%s]\n' "${1:-}"
}

echo "== seeding local origins"
mkdir -p "$tmp/origins/alice"

git init -q --bare -b main "$tmp/origins/alice/repo-one.git"
git init -q --bare -b main "$tmp/origins/alice/repo-two.git"

git init -q -b main "$tmp/work"
cd "$tmp/work"
git config user.name test
git config user.email test@example.com
git config commit.gpgsign false
git remote add origin "$tmp/origins/alice/repo-one.git"

echo one > f
git add f
git commit -qm A
sha_a=$(git rev-parse HEAD)
git push -q origin main

echo two >> f
git commit -qam B
sha_b=$(git rev-parse HEAD)
git push -q origin main

git checkout -qb feature
echo three > g
git add g
git commit -qm D
sha_d=$(git rev-parse HEAD)
git push -q origin feature
git checkout -q main

json_repos ',{"full_name":"alice/repo-two","archived":false}' > "$FAKE_REPOS_JSON"
mirror="$ROOT/mirrors/alice/repo-one.git"

echo "== first run creates mirrors"
check "backup exits 0"            "\"$here/bin/backup.sh\""
check "main matches origin"       "[ \"\$(git -C '$mirror' rev-parse refs/heads/main)\" = '$sha_b' ]"
check "feature branch mirrored"   "git -C '$mirror' rev-parse -q --verify refs/heads/feature"
check "second repo mirrored"      "[ -d '$ROOT/mirrors/alice/repo-two.git' ]"
check "no archive refs yet"       "[ -z \"\$(git -C '$mirror' for-each-ref refs/archive)\" ]"
check "repos.known has 2 lines"   "[ \"\$(wc -l < '$ROOT/repos.known')\" = 2 ]"

echo "== a fast-forward must not create archive refs"
git -C "$tmp/work" commit -q --allow-empty -m C
git -C "$tmp/work" push -q origin main
sha_c=$(git -C "$tmp/work" rev-parse HEAD)
check "backup exits 0"            "\"$here/bin/backup.sh\""
check "main advanced"             "[ \"\$(git -C '$mirror' rev-parse refs/heads/main)\" = '$sha_c' ]"
check "still no archive refs"     "[ -z \"\$(git -C '$mirror' for-each-ref refs/archive)\" ]"

echo "== force-push must not destroy the old tip"
git -C "$tmp/work" push -q -f origin "$sha_a:main"
check "backup exits 0"            "\"$here/bin/backup.sh\""
check "main rolled back"          "[ \"\$(git -C '$mirror' rev-parse refs/heads/main)\" = '$sha_a' ]"
check "old tip pinned"            "[ \"\$(git -C '$mirror' rev-parse refs/archive/$sha_c)\" = '$sha_c' ]"
check "pin recorded in ledger"    "grep -q '$sha_c' '$ROOT/ledger/pinned.tsv'"

echo "== pinned objects survive an aggressive gc"
check "gc --prune=now runs"       "git -C '$mirror' gc --prune=now -q"
check "pinned commit still exists" "git -C '$mirror' cat-file -e '$sha_c'"
check "pinned history intact"     "git -C '$mirror' log --format=%H refs/archive/$sha_c | grep -q '$sha_b'"

echo "== branch deletion must not destroy the branch"
git -C "$tmp/work" push -q origin --delete feature
check "backup exits 0"            "\"$here/bin/backup.sh\""
check "branch gone from mirror"   "! git -C '$mirror' rev-parse -q --verify refs/heads/feature"
check "deleted tip pinned"        "[ \"\$(git -C '$mirror' rev-parse refs/archive/$sha_d)\" = '$sha_d' ]"

echo "== a repo vanishing upstream must not delete the local mirror"
json_repos > "$FAKE_REPOS_JSON"
check "backup exits 0"            "\"$here/bin/backup.sh\""
check "mirror kept on disk"       "[ -d '$ROOT/mirrors/alice/repo-two.git' ]"
check "vanish recorded"           "grep -q 'alice/repo-two' '$ROOT/ledger/vanished.tsv'"
check "repos.known shrunk"        "[ \"\$(wc -l < '$ROOT/repos.known')\" = 1 ]"

echo "== API failure aborts without side effects"
before=$(md5sum "$ROOT/repos.known" | cut -d' ' -f1)
if FAKE_API_FAIL=1 "$here/bin/backup.sh" > /dev/null 2>&1; then
    bad "backup should have failed"
else
    ok "backup fails closed"
fi
after=$(md5sum "$ROOT/repos.known" | cut -d' ' -f1)
check "manifest untouched"        "[ '$before' = '$after' ]"

echo "== ledger records events once"
cat > "$tmp/events.json" <<'JSON'
[
 {"id":"1001","type":"PushEvent","created_at":"2026-01-01T00:00:00Z",
  "actor":{"login":"agent"},"payload":{"ref":"refs/heads/main","before":"aaa","after":"bbb","forced":true}},
 {"id":"1002","type":"WatchEvent","created_at":"2026-01-01T00:00:01Z",
  "actor":{"login":"someone"},"payload":{}}
]
JSON
export FAKE_EVENTS_JSON="$tmp/events.json"
check "ledger exits 0"            "\"$here/bin/ledger.sh\""
check "ledger exits 0 again"      "\"$here/bin/ledger.sh\""
check "only PushEvent kept"       "[ \"\$(wc -l < '$ROOT/ledger/events.jsonl')\" = 1 ]"
check "no duplicate on rerun"     "[ \"\$(wc -l < '$ROOT/ledger/events.jsonl')\" = 1 ]"
check "before-sha captured"       "grep -q '\"before\":\"aaa\"' '$ROOT/ledger/events.jsonl'"
check "forced flag captured"      "grep -q '\"forced\":true' '$ROOT/ledger/events.jsonl'"

echo "== bundles are self-contained and pinning survives the repack audit"
check "bundle run exits 0"        "BUNDLE_INTERVAL=0 \"$here/bin/bundle.sh\""
bundle=$(find "$ROOT/bundles" -name 'repo-one.bundle' | head -1)
check "bundle written"            "[ -n '$bundle' ]"
check "bundle verifies"           "git -C '$mirror' bundle verify -q '$bundle'"
check "bundle clones standalone"  "git clone -q '$bundle' '$tmp/frombundle'"
check "bundled repo has history"  "git -C '$tmp/frombundle' rev-parse -q --verify HEAD"
check "pin survived repack+prune" "git -C '$mirror' cat-file -e '$sha_c'"

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m%s checks passed\033[0m\n' "$pass"
else
    printf '\033[31m%s passed, %s FAILED\033[0m\n' "$pass" "$fail"
    exit 1
fi
