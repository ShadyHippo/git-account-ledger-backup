# git-account-ledger-backup

An append-only backup of every repository on a GitHub account, public and
private, designed for the case where agents have force-push rights and you do
not want to take those rights away.

It is not a mirror. A mirror faithfully reproduces damage: `git fetch --prune`
deletes the branch an agent just force-pushed over. This keeps what a mirror
throws away.

## What it actually guarantees

- **Force-pushed history survives.** Every tip that becomes unreachable is
  preserved under `refs/archive/<sha>`, a namespace the fetch never touches, so
  `git gc` cannot collect it.
- **Deleted branches survive.** Same mechanism.
- **Deleted repositories survive.** A repo that disappears from the API is
  logged and its mirror is kept. The script never deletes a local repo.
- **New repositories appear automatically.** Discovery runs against
  `/user/repos` every cycle, so nothing needs to be added by hand.
- **A failed API call fails closed.** If discovery errors, the run aborts
  before touching anything, rather than treating an outage as "no repos".
- **Every push event is recorded** with `before`/`after`/`forced`/`actor`, at
  15-minute resolution. This catches what the hourly mirror structurally
  cannot: a force-push that is itself force-pushed back leaves the ref
  unchanged, so the mirror sees nothing, but the ledger saw both events.

## Quick start

```bash
git clone https://github.com/ShadyHippo/git-account-ledger-backup.git
cd git-account-ledger-backup
cp compose.yaml compose.local.yaml
$EDITOR compose.local.yaml      # paste your token, check the path
docker compose -f compose.local.yaml up -d
docker exec gitarchive /usr/local/bin/entrypoint.sh backup   # first run, watch it
```

On Unraid: create the share `gitarchive` with **Use cache: no** (array only —
if the mover puts this on the cache it is outside parity and on the drive most
likely to fail), then paste `compose.yaml` into the Compose Manager plugin, or
translate the fields into a normal Unraid container template (no ports, one path
mapping `/mnt/user/gitarchive` → `/data`, one env var).

### The token

Fine-grained personal access token:

- **Repository access:** All repositories
- **Permissions:** Contents → **Read-only**. Nothing else. (Metadata is implied.)
- Expiry: 1 year, with a calendar reminder.

That is enough to clone, fetch, read LFS and read the events API, and it cannot
modify anything. If you would rather not have a static secret, a GitHub App
installed on your account with the same read-only Contents permission works
too — mint a 1-hour installation token per run.

## What lands on disk

```
/data/
  mirrors/<owner>/<repo>.git     live mirror, pruned every cycle
  ledger/events.jsonl            every PushEvent, append-only
  ledger/pinned.tsv              every tip preserved, with the reason
  ledger/vanished.tsv            repos that disappeared upstream
  bundles/YYYY-MM/…              monthly self-contained bundle per repo
  log/{backup,ledger,bundle,fsck,lfs}.log
  status/last-backup-ok          drives the healthcheck
  repos.known                    manifest; never used to delete anything
```

`mirrors/` is a normal bare repo per project. You can `git clone` it directly,
`git log` it, or serve it — it is not a proprietary format.

## Recovering

Everything below runs inside the container, except `push`.

**A branch that was force-pushed or deleted**

```bash
docker exec gitarchive /usr/local/bin/restore.sh events owner/repo
# → {"at":"2026-10-21T14:02:11Z","actor":"agent","ref":"refs/heads/master",
#    "before":"<sha-you-want>","after":"...","forced":true}
```

Restore it with the write token, either by pushing the old tip back into the
same branch or into a new one. Never keep the write token on the server.

**A repository that was deleted upstream**

```bash
WRITE_TOKEN=...   # Contents:write AND Workflows:write, in your shell only
docker exec -e GITHUB_WRITE_TOKEN="$WRITE_TOKEN" gitarchive \
  /usr/local/bin/restore.sh push owner/repo owner/repo-restored
```

Explicit refspecs are used rather than `git push --mirror`, so `refs/archive/*`
is never pushed into the new repository. If any commit in history touches
`.github/workflows`, GitHub rejects the push unless the token has
**Workflows: write** — this is the failure people hit in the middle of a
disaster, so test it once now.

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

## Knobs

| Variable | Default | Meaning |
|---|---|---|
| `GITHUB_RO_TOKEN` | — | read-only token (or use `GITHUB_RO_TOKEN_FILE`) |
| `BACKUP_INTERVAL` | `3600` | seconds between mirror runs |
| `LEDGER_INTERVAL` | `900` | seconds between event polls |
| `BUNDLE_INTERVAL` | `2592000` | seconds between bundle + repack |
| `ROOT` | `/data` | storage root inside the container |

Scale the intervals to your account. 100 repos at a 15-minute ledger poll is
~400 API calls/hour against a 5,000/hour limit.

## Limitations worth knowing

- **Issues, PRs, release binaries and wikis are not in git.** Code and history
  only. If you need those, run `josegonzalez/python-github-backup` alongside
  this for the API side.
- Submodule contents are not fetched; only the pointer commits.
- If a commit is pushed and force-pushed away inside one interval, the mirror
  never sees it. The ledger records that it happened (the SHA, actor and time),
  but the objects were never fetched. Shorten `BACKUP_INTERVAL` to narrow this.
- The container trusts its own filesystem. Any process that can write to
  `/data` can do damage, so do not mount that share into agent containers, and
  do not mount `/mnt/user/appdata` wholesale into them either.

## Development

```bash
make test     # 37 checks, no network, no Docker
make build
```

The test suite drives the real scripts against local bare repositories with a
fake API, and asserts the important property directly: after a force-push, an
aggressive `git gc --prune=now` leaves the pinned commits intact.
