#!/usr/bin/env bash
# Adversarial recovery proof.
#
# Simulates a misbehaving agent: divergent force-pushes, real pushes stacked on
# top of them, force-pushes back to old commits, tag retargeting, branch
# deletion and recreation, and two force-pushes inside a single backup interval.
#
# Then it garbage-collects everything and asks whether every state is still
# recoverable, and whether content is byte-identical.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export ROOT="$tmp/data"
export GIT_BASE_URL="file://$tmp/origins"
export CONFIG_FILE="$tmp/config.json"
export FAKE_ROOT="$tmp/api"
export GITHUB_RO_TOKEN="tok-agent"
export PATH="$here/tests/fakebin:$PATH"
unset GITHUB_RO_TOKENS PUBLIC_REPOS PUBLIC_ACCOUNTS BRANCH_POLICY CONFIG_WARNINGS || true

mkdir -p "$FAKE_ROOT" "$tmp/work"

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if ( set +o pipefail; eval "$2" ) > /dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

O="$tmp/origins/agent/target.git"
mkdir -p "$(dirname "$O")"
git init -q --bare -b main "$O"
# GitHub allows fetching a commit by SHA even when it is no longer reachable.
git -C "$O" config uploadpack.allowAnySHA1InWant true
git -C "$O" config uploadpack.allowReachableSHA1InWant true
# Servers normally refuse deleting the branch HEAD points at; the scenario we
# care about is a branch delete being observed by the archiver.
git -C "$O" config receive.denyDeleteCurrent warn

w="$tmp/work/repo"
git init -q -b main "$w"
git -C "$w" config user.name agent
git -C "$w" config user.email agent@example.com
git -C "$w" config commit.gpgsign false
git -C "$w" remote add origin "$O"

tree_with() { # content -> tree
    local blob
    blob=$(printf '%s\n' "$1" | git -C "$w" hash-object -w --stdin)
    printf '100644 blob %s\tf\n' "$blob" | git -C "$w" mktree
}
mkroot()  { git -C "$w" commit-tree "$(tree_with "$1")" -m "$2"; }
mkchild() { git -C "$w" commit-tree "$(tree_with "$2")" -p "$1" -m "$3"; }

printf '{"login":"agent"}' > "$FAKE_ROOT/user_tok-agent.json"
printf '[{"full_name":"agent/target","default_branch":"main"}]' > "$FAKE_ROOT/userrepos_tok-agent.json"
printf '{"accounts":[{"token":"tok-agent","branches":"all"}]}' > "$CONFIG_FILE"

M="$ROOT/sources/agent/mirrors/agent/target.git"
backup() { "$here/bin/backup.sh"; }

echo "== building history A -> B -> C, tag v1"
A=$(mkroot A A)
B=$(mkchild "$A" B B)
C=$(mkchild "$B" C C)
git -C "$w" push -q origin "$A:refs/heads/main"
git -C "$w" push -q origin "$B:refs/heads/main"
git -C "$w" push -q origin "$C:refs/heads/main"
git -C "$w" push -q origin "$C:refs/tags/v1"
check "initial backup"            "backup"
check "main is C"                 "[ \"\$(git -C '$M' rev-parse refs/heads/main)\" = '$C' ]"
check "tag v1 is C"               "[ \"\$(git -C '$M' rev-parse refs/tags/v1)\" = '$C' ]"

echo "== S1: force-push to a divergent root X (not an ancestor of anything)"
X=$(mkroot X X)
git -C "$w" push -q -f origin "$X:refs/heads/main"
check "backup"                    "backup"
check "main is X"                 "[ \"\$(git -C '$M' rev-parse refs/heads/main)\" = '$X' ]"
check "C pinned"                  "[ \"\$(git -C '$M' rev-parse refs/archive/$C)\" = '$C' ]"
check "B still present"           "git -C '$M' cat-file -e '$B'"
check "A still present"           "git -C '$M' cat-file -e '$A'"

echo "== S2: real push D on top of X"
D=$(mkchild "$X" D D)
git -C "$w" push -q origin "$D:refs/heads/main"
check "backup"                    "backup"
check "main is D"                 "[ \"\$(git -C '$M' rev-parse refs/heads/main)\" = '$D' ]"
check "C still pinned"            "git -C '$M' cat-file -e '$C'"

echo "== S3: force-push back to A, orphaning the whole X branch"
git -C "$w" push -q -f origin "$A:refs/heads/main"
check "backup"                    "backup"
check "main is A"                 "[ \"\$(git -C '$M' rev-parse refs/heads/main)\" = '$A' ]"
check "D pinned"                  "[ \"\$(git -C '$M' rev-parse refs/archive/$D)\" = '$D' ]"
check "X reachable via D"         "git -C '$M' merge-base --is-ancestor '$X' '$D'"

echo "== S4: real push E on A (B and C are now unreachable again)"
E=$(mkchild "$A" E E)
git -C "$w" push -q origin "$E:refs/heads/main"
check "backup"                    "backup"
check "main is E"                 "[ \"\$(git -C '$M' rev-parse refs/heads/main)\" = '$E' ]"
check "B survives despite being unreachable from E" "git -C '$M' cat-file -e '$B'"
check "C survives despite being unreachable from E" "git -C '$M' cat-file -e '$C'"

echo "== S5: force-push to orphan F"
F=$(mkroot F F)
git -C "$w" push -q -f origin "$F:refs/heads/main"
check "backup"                    "backup"
check "main is F"                 "[ \"\$(git -C '$M' rev-parse refs/heads/main)\" = '$F' ]"
check "E pinned"                  "[ \"\$(git -C '$M' rev-parse refs/archive/$E)\" = '$E' ]"

echo "== S6: delete the branch entirely"
git -C "$w" push -q origin --delete main
check "backup"                    "backup"
check "no main branch"            "! git -C '$M' rev-parse -q --verify refs/heads/main"
check "F pinned on deletion"      "[ \"\$(git -C '$M' rev-parse refs/archive/$F)\" = '$F' ]"

echo "== S7: recreate main at an old commit"
git -C "$w" push -q origin "$A:refs/heads/main"
check "backup"                    "backup"
check "main is A again"           "[ \"\$(git -C '$M' rev-parse refs/heads/main)\" = '$A' ]"

echo "== S8: tag-only commit, then retarget the tag"
G=$(mkroot G G)
git -C "$w" push -q origin "$G:refs/tags/v2"
check "backup"                    "backup"
check "tag v2 points at G"        "[ \"\$(git -C '$M' rev-parse refs/tags/v2)\" = '$G' ]"
git -C "$w" push -q -f origin "$A:refs/tags/v2"
check "backup after retarget"     "backup"
check "old tag commit pinned"     "[ \"\$(git -C '$M' rev-parse refs/archive/$G)\" = '$G' ]"
check "tag now points at A"       "[ \"\$(git -C '$M' rev-parse refs/tags/v2)\" = '$A' ]"

echo "== S9: two unrelated force-pushes inside one backup interval"
H1=$(mkroot H1 H1)
H3=$(mkroot H3 H3)
git -C "$w" push -q -f origin "$H1:refs/heads/main"
git -C "$w" push -q -f origin "$H3:refs/heads/main"
check "backup"                    "backup"
check "main is H3"                "[ \"\$(git -C '$M' rev-parse refs/heads/main)\" = '$H3' ]"
check "H1 was never fetched (known gap)" "! git -C '$M' cat-file -e '$H1'"

echo "== the ledger still knows about H1"
cat > "$FAKE_ROOT/events_agent_target.json" <<JSON
[
 {"id":"1","type":"PushEvent","created_at":"2026-01-01T01:00:00Z","actor":{"login":"agent"},
  "payload":{"ref":"refs/heads/main","before":"$C","after":"$X","forced":true}},
 {"id":"2","type":"PushEvent","created_at":"2026-01-01T02:00:00Z","actor":{"login":"agent"},
  "payload":{"ref":"refs/heads/main","before":"$X","after":"$D","forced":false}},
 {"id":"3","type":"PushEvent","created_at":"2026-01-01T03:00:00Z","actor":{"login":"agent"},
  "payload":{"ref":"refs/heads/main","before":"$D","after":"$A","forced":true}},
 {"id":"4","type":"PushEvent","created_at":"2026-01-01T04:00:00Z","actor":{"login":"agent"},
  "payload":{"ref":"refs/heads/main","before":"$A","after":"$E","forced":false}},
 {"id":"5","type":"PushEvent","created_at":"2026-01-01T05:00:00Z","actor":{"login":"agent"},
  "payload":{"ref":"refs/heads/main","before":"$E","after":"$F","forced":true}},
 {"id":"6","type":"PushEvent","created_at":"2026-01-01T06:00:00Z","actor":{"login":"agent"},
  "payload":{"ref":"refs/heads/main","before":"$F","after":"$H1","forced":true}},
 {"id":"7","type":"PushEvent","created_at":"2026-01-01T06:05:00Z","actor":{"login":"agent"},
  "payload":{"ref":"refs/heads/main","before":"$H1","after":"$H3","forced":true}}
]
JSON
check "ledger run"                "\"$here/bin/ledger.sh\""
check "ledger recorded H1 as a before-sha" "grep -q '$H1' '$ROOT/sources/agent/ledger/events.jsonl'"
check "state flags H1 as missing before rescue" \
    "\"$here/bin/restore.sh\" state agent/target 2026-01-01T06:02:00Z | grep -q MISSING"

echo "== rescue pulls H1 back from upstream and pins it"
check "rescue succeeds"           "\"$here/bin/restore.sh\" rescue agent/target '$H1'"
check "H1 now present"            "git -C '$M' cat-file -e '$H1^{commit}'"
check "H1 pinned"                 "[ \"\$(git -C '$M' rev-parse refs/archive/$H1)\" = '$H1' ]"

echo "== everything survives an aggressive gc"
check "gc --prune=now"            "git -C '$M' gc --prune=now -q"
for pair in "A:$A" "B:$B" "C:$C" "X:$X" "D:$D" "E:$E" "F:$F" "G:$G" "H1:$H1" "H3:$H3"; do
    name=${pair%%:*}
    sha=${pair#*:}
    check "commit $name survives gc" "git -C '$M' cat-file -e '$sha^{commit}'"
done

echo "== content fidelity, not just object presence"
check "A content intact"          "[ \"\$(git -C '$M' show $A:f)\" = A ]"
check "C content intact"          "[ \"\$(git -C '$M' show $C:f)\" = C ]"
check "D content intact"          "[ \"\$(git -C '$M' show $D:f)\" = D ]"
check "E content intact"          "[ \"\$(git -C '$M' show $E:f)\" = E ]"
check "F content intact"          "[ \"\$(git -C '$M' show $F:f)\" = F ]"

echo "== reconstruct the branch as it was at a past moment"
check "state at 02:30 shows D"    "[ \"\$(\"$here/bin/restore.sh\" state agent/target 2026-01-01T02:30:00Z | awk '\$1==\"main\"{print \$2}')\" = '$D' ]"
check "state at 03:30 shows A"    "[ \"\$(\"$here/bin/restore.sh\" state agent/target 2026-01-01T03:30:00Z | awk '\$1==\"main\"{print \$2}')\" = '$A' ]"
check "state at 05:30 shows F"    "[ \"\$(\"$here/bin/restore.sh\" state agent/target 2026-01-01T05:30:00Z | awk '\$1==\"main\"{print \$2}')\" = '$F' ]"
check "state at 06:30 shows H3"   "[ \"\$(\"$here/bin/restore.sh\" state agent/target 2026-01-01T06:30:00Z | awk '\$1==\"main\"{print \$2}')\" = '$H3' ]"
check "state materializes a worktree" "\"$here/bin/restore.sh\" state agent/target 2026-01-01T05:30:00Z '$tmp/past'"
check "materialized branch is F"  "[ \"\$(git -C '$tmp/past' rev-parse main)\" = '$F' ]"
check "materialized file is F"    "[ \"\$(cat '$tmp/past/f')\" = F ]"

echo "== offline integrity proof, no network"
check "verify passes"             "\"$here/bin/verify.sh\""
check "verify wrote an attestation" "[ -s '$ROOT/verify/last-ok' ]"
check "verify recorded a digest"  "tail -1 '$ROOT/verify/history.tsv' | grep -q 'sha256:'"
check "full verification passes"  "\"$here/bin/verify.sh\" --full --drill 5"
check "digest is stable across runs" \
    "[ \"\$(tail -1 '$ROOT/verify/history.tsv' | cut -f6)\" = \"\$(tail -2 '$ROOT/verify/history.tsv' | head -1 | cut -f6)\" ]"

echo "== verify catches a promise that was silently lost"
# fsck alone cannot see this: the object is unreferenced and simply gone.
git -C "$M" update-ref -d "refs/archive/$G"
git -C "$M" gc --prune=now -q
check "fsck still says the repo is fine" "git -C '$M' fsck --connectivity-only --no-progress"
out=$("$here/bin/verify.sh" 2>&1) && rc=0 || rc=$?
check "verify fails"              "[ '$rc' -ne 0 ]"
check "verify names the lost commit" "printf '%s' \"\$out\" | grep -q '$G'"

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m%s checks passed\033[0m\n' "$pass"
else
    printf '\033[31m%s passed, %s FAILED\033[0m\n' "$pass" "$fail"
    exit 1
fi
