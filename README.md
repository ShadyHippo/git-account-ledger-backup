# git-account-ledger-backup

An append-only archive of one or more GitHub accounts, public or private, plus
any third-party repos you point it at. Built for the case where agents have
force-push rights and you do not want to take those rights away.

It is not a mirror. A mirror faithfully reproduces damage: `git fetch --prune`
deletes the branch an agent just force-pushed over. This keeps what a mirror
throws away.

## What it guarantees

Per source:

- **Force-pushed history survives.** Every tip that becomes unreachable is
  preserved under `refs/archive/<sha>`, a namespace the fetch never touches, so
  `git gc` cannot collect it.
- **Deleted branches survive.** Same mechanism.
- **Deleted repositories and deleted accounts survive.** A repo that stops
  existing upstream is marked *retired* and its mirror is kept. A source whose
  account disappeared is marked *unreachable* and frozen. Nothing is ever
  deleted because it stopped being visible.
- **An API outage does not stop the backup.** Discovery failure falls back to
  the known repo list, so a revoked token or a GitHub incident still fetches.
- **Damage is noticed.** If a mirror disappears from disk it is rebuilt and
  reported `CRITICAL`, and the run is marked unhealthy, because the history and
  pinned tips that went with it are gone.
- **Every push event is recorded** with `before`/`after`/`forced`/`actor` at
  15-minute resolution. This catches what the hourly mirror structurally
  cannot: a force-push that is itself force-pushed back leaves the ref
  unchanged, but the ledger saw both events.

## Multiple accounts

Each token's account gets its own directory. Supply an array:

```yaml
environment:
  GITHUB_RO_TOKENS: "github_pat_aaa,github_pat_bbb"
```

Comma separated, newline separated, or a JSON array — all work. Each token is
resolved to a login via the API and stored at `/data/sources/<login>/`. Two
tokens for the same login merge into one source. The mapping is persisted in
`/data/.sources.tsv`, so a **revoked token still finds its own archive** instead
of creating a new empty directory.

A repo visible to two accounts is stored once, under the first source that saw
it.

## Third-party repos that could vanish

Point it at someone else's repo or a whole account:

```yaml
environment:
  PUBLIC_REPOS: "someuser/SomethingInteresting,another/repo"
  PUBLIC_ACCOUNTS: "artcraft"
```

```json
{ "public": [ { "repo": "artcraft/art", "branches": "main,release/*" } ] }
```

Public sources work without a token, but a token is used when one exists
because the anonymous rate limit is 60 requests/hour. If `artcraft` is deleted
tomorrow, `/data/sources/artcraft/` stays exactly as it is, forever, and every
later run simply logs that the source is unreachable.

## Branch policy

```yaml
BRANCH_POLICY: "all"            # every branch
BRANCH_POLICY: "default"        # only the repository's default branch
BRANCH_POLICY: "main,release/*" # explicit, globs allowed
```

Per source in `config.json`:

```json
{ "accounts": [ { "token": "...", "branches": "default" } ],
  "public":   [ { "owner": "artcraft", "branches": "main,release/*" } ] }
```

Tags are always fetched. Tightening a policy never removes branches already
archived; it only stops new ones from being followed.

## Layout

```
/data/
  sources/<login>/                       one directory per account
    mirrors/<owner>/<repo>.git           normal bare repos
    ledger/events.jsonl                  every PushEvent
    ledger/pinned.tsv                    every tip preserved, with the reason
    ledger/snapshots.tsv                 prune boundaries
    ledger/vanished.tsv                  repos that disappeared upstream
    state/repos.tsv                      tracked repos + default branch
    state/retired.tsv                    frozen repos, never re-fetched
    state/state                          ok | unreachable
    state/last-backup-ok
  bundles/<login>/YYYY-MM/…              monthly standalone bundles
  bundles/<login>/snapshots/…            pre-prune escape hatches
  log/                                   backup, ledger, fsck, lfs, snapshot
```

`mirrors/` is a plain bare repo per project. `git clone` it, `git log` it, serve
it — nothing proprietary.

## Space

Order of magnitude, and the honest answer to "will this ever hit 100 GB":

| Component | Cost |
|---|---|
| Full history of a text repo | ~1× the repo's own size |
| Pinned force-pushed tips | small; blobs deduplicate by SHA |
| Tip-only snapshot | ~the size of one checkout |
| Monthly bundle | **1× the repo per generation** (bundles do not dedupe) |
| LFS objects | the full size of every LFS object ever fetched |

So roughly `Σ(repos) × (1 + bundle generations kept) + LFS + pins`.

For an account of ordinary source-code repos, 100 GB is a long way off: the
median repo is a few MB, and 100 of them is low single-digit GB. What breaks
that math is **content**, not history — art assets, models, datasets, committed
videos, LFS, or a repo with a large binary in its history. `artcraft`, if it is
an art project with source files, could be several GB on its own.

Check with real numbers instead of guessing:

```bash
docker exec gitarchive /usr/local/bin/stats.sh
```

It prints per-repo size, commit count, pinned tips, and what each source's
bundles are costing you. Lower `BUNDLE_KEEP` to 2–3 if bundles dominate.

## Pruning to a snapshot

Two modes, both manual, both requiring `--yes`, both writing and verifying a
bundle first so the state you are discarding exists somewhere:

```bash
docker exec gitarchive /usr/local/bin/snapshot.sh list alpha
docker exec gitarchive /usr/local/bin/snapshot.sh repo alpha alpha/repo-one --mode archive --yes
docker exec gitarchive /usr/local/bin/snapshot.sh source artcraft --mode tip --yes
```

**`--mode archive`** drops `refs/archive/*` and repacks. Branch history is
untouched. This frees whatever force-pushed history you had accumulated and
keeps the mirror a normal full clone. Conservative.

**`--mode tip`** replaces the mirror with a `--depth 1` shallow clone. You keep
today's content and the **same tip commit SHAs**, so the ledger stays
continuous — nothing rewrites history, it just stops carrying it. Everything
before the boundary is gone from the mirror; the pre-snapshot bundle is the only
way back.

After a `tip` snapshot, subsequent fetches stay shallow (`--depth 1`), the
ledger keeps recording, and force-push protection keeps working for commits
after the boundary. Recovery of a commit from before it means restoring from the
bundle.

`sources/<login>/ledger/snapshots.tsv` records each boundary: timestamp, repo,
mode, size before and after, and the tip SHAs, so "what did I collapse, and
when" is answerable later.

## Recovery

**A branch that was force-pushed or deleted**

```bash
docker exec gitarchive /usr/local/bin/restore.sh events owner/repo
# → {"at":"...","actor":"agent","ref":"refs/heads/master",
#    "before":"<sha-you-want>","after":"...","forced":true}
```

**A repo that was deleted upstream**

```bash
export GITHUB_WRITE_TOKEN=...   # in your shell only, never in the container
docker exec -e GITHUB_WRITE_TOKEN="$GITHUB_WRITE_TOKEN" gitarchive \
  /usr/local/bin/restore.sh push owner/repo owner/repo-restored
```

Explicit refspecs are used rather than `git push --mirror`, so `refs/archive/*`
is never pushed into the new repo. If any commit touches `.github/workflows`,
GitHub rejects the push unless the token has **Workflows: write** — test this
once now, not in the middle of a disaster.

**A commit nobody remembers**

```bash
docker exec gitarchive /usr/local/bin/restore.sh pinned owner/repo
docker exec gitarchive /usr/local/bin/restore.sh clone owner/repo /tmp/r
git -C /tmp/r branch rescue <sha>
```

**Off-array copy.** `bundles/YYYY-MM/` is self-contained; each file is
`git bundle verify`-able and cloneable with no dependency on this container.
Sync that tree to an external drive or object storage monthly. That is the copy
that survives the NAS.

## Quick start

```bash
git clone https://github.com/ShadyHippo/git-account-ledger-backup.git
cd git-account-ledger-backup
cp compose.yaml compose.local.yaml
$EDITOR compose.local.yaml      # token(s), public repos, share path
docker compose -f compose.local.yaml up -d
docker exec gitarchive /usr/local/bin/entrypoint.sh backup
```

On Unraid: create the share `gitarchive` with **Use cache: no** (array only —
on the cache it is outside parity), then paste `compose.yaml` into Compose
Manager or translate it into a container template. No ports.

### Tokens

Fine-grained PAT, **All repositories**, **Contents: Read-only**. Nothing else.
One per account. Expiry with a reminder.

The read-only token must not be reachable by the agent containers: mount
specific paths into them, never `/mnt/user/appdata` wholesale. A read-only token
is still a key to every private repo you own.

The **write** token for restores lives in your password manager and is passed
with `docker exec -e` when needed. That asymmetry is the security model: the
server can read, only you can rewrite.

## Knobs

| Variable | Default | Meaning |
|---|---|---|
| `GITHUB_RO_TOKENS` | — | one or more read-only PATs |
| `PUBLIC_REPOS` | — | `owner/repo` list to archive |
| `PUBLIC_ACCOUNTS` | — | owners to enumerate publicly |
| `BRANCH_POLICY` | `all` | `all`, `default`, or `main,release/*` |
| `BACKUP_INTERVAL` | `3600` | seconds between mirror runs |
| `LEDGER_INTERVAL` | `900` | seconds between event polls |
| `BUNDLE_INTERVAL` | `2592000` | seconds between bundle + repack |
| `BUNDLE_KEEP` | `6` | bundle generations retained |
| `CONFIG_FILE` | `/config/config.json` | optional per-source policies |

100 repos at a 15-minute ledger poll is ~400 API calls/hour against a
5,000/hour limit.

## Limitations

- **Issues, PRs, release assets and wikis are not in git.** Code and history
  only. Run `josegonzalez/python-github-backup` alongside for the API side.
- Submodule contents are not fetched, only the pointer commits.
- **Bundles do not contain LFS objects.** `git bundle` only carries git
  objects, so for an LFS repo the monthly bundle is history-only; the LFS
  objects exist solely in `mirrors/<owner>/<repo>.git/lfs`. If you rely on LFS
  and need the off-array copy to be complete, handle that directory separately.
- A commit pushed and force-pushed away inside one interval is never fetched.
  The ledger records the SHA, actor and time, but the objects do not exist
  locally. Shorten `BACKUP_INTERVAL` to narrow this.
- Bundle retention (`BUNDLE_KEEP`) is the one place this project deletes
  anything. It deletes a copy, never the archive.
- `--mode tip` is irreversible without the pre-snapshot bundle.
- Upgrading from 1.x: the layout moved from `/data/mirrors` to
  `/data/sources/<login>/`. The old directory is untouched by 2.x; move or
  delete it yourself once you are happy.

## Development

```bash
make test     # 55 checks, no network, no Docker
make build
```

The suite drives the real scripts against local bare repositories with a fake
API. It asserts the properties that matter directly: pinned commits survive
`git gc --prune=now`, a deleted repo is retired rather than removed, an API
outage still backs up from the known list, a missing mirror is reported, and the
three branch policies select the right refs.
