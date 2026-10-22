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

Three questions, in order: *which state do I want*, *which SHA is that*, *do I
have the object*.

### How hard it actually is

| Situation | Effort |
|---|---|
| A branch was force-pushed or deleted while you were watching | **seconds** — `restore.sh events`, push the `before` SHA back |
| You know roughly when, not which SHA | **seconds** — `restore.sh state <repo> <timestamp>` |
| The commit was fetched at some point and is no longer reachable | **seconds** — it is pinned; `restore.sh pinned`, then `git branch rescue <sha>` |
| Pushed and rewritten away *between* two backup runs | **minutes** — `restore.sh rescue`, if upstream still has the object |
| Upstream collected the object and it was never fetched | **unrecoverable** — the only real loss window |

Everything is keyed on full SHAs, so recovery never depends on the current
branch surviving.

### What did the branch look like at 14:32?

```bash
docker exec gitarchive /usr/local/bin/restore.sh state owner/repo 2026-10-21T14:32:00Z
```

```
main                          4c1e...  present
release/1.0                   a992...  present
feature/rewrite               8b03...  MISSING -> restore.sh rescue owner/repo 8b03...
```

That is reconstructed from the ledger's recorded push events, so it is accurate
to the push, not to the poll interval — each event carries GitHub's `created_at`.
Add a destination to materialise it:

```bash
docker exec gitarchive /usr/local/bin/restore.sh state owner/repo 2026-10-21T14:32:00Z /tmp/then
```

which clones the mirror and force-creates each branch at its historical tip, so
`/tmp/then` is that project as it stood at that moment.

### Rescuing a commit the ledger knows about

If an agent force-pushed twice between two backup runs, the mirror saw only the
final state. The intermediate commit was never downloaded — but the ledger has
its SHA from the `PushEvent`. GitHub keeps unreachable objects for a while and
permits fetching by SHA, so this usually still works:

```bash
docker exec gitarchive /usr/local/bin/restore.sh rescue owner/repo <sha>
```

It fetches that one commit from upstream, pins it to `refs/archive/<sha>`, and
records the rescue in `pinned.tsv`. If upstream has already collected it, the
command says so plainly instead of failing obscurely. This is the trade for the
`BACKUP_INTERVAL` window, and it is why the ledger stores `before` as well as
`after`.

### Pushing a recovered state back

```bash
export GITHUB_WRITE_TOKEN=...   # in your shell only, never in the container
docker exec -e GITHUB_WRITE_TOKEN="$GITHUB_WRITE_TOKEN" gitarchive \
  /usr/local/bin/restore.sh push owner/repo owner/repo-restored
```

Explicit refspecs are used rather than `git push --mirror`, so `refs/archive/*`
is never pushed into the new repo. If any commit touches `.github/workflows`,
GitHub rejects the push unless the token has **Workflows: write** — test this
once now, not in the middle of a disaster.

### Proof: adversarial sequences

`tests/test-adversarial.sh` runs one repo through a deliberately misbehaving
agent, takes a backup after every step, then `git gc --prune=now` and checks
every state is still there *and* byte-identical:

| Step | Action | Result |
|---|---|---|
| S1 | force-push to a divergent root, orphaning A→B→C | C pinned, B and A survive through it |
| S2 | real push D on top of the divergent root | D fetches normally, C still pinned |
| S3 | force-push back to A, orphaning X→D | D pinned, X survives through it |
| S4 | real push E on A (B, C unreachable again) | B and C survive via the earlier pin |
| S5 | force-push to an unrelated orphan F | E pinned |
| S6 | delete the branch entirely | F pinned, no branch left |
| S7 | recreate main at an old commit | resolves to A, nothing lost |
| S8 | commit reachable only via a tag, then retarget the tag | old tag commit pinned |
| S9 | two unrelated force-pushes inside one interval | final state kept; intermediate flagged and recoverable by `rescue` |

All eleven commits survive the gc, and `show <sha>:f` returns the original
content for each. Reconstructed states at four different timestamps match what
the branch pointed at then.

That is 135 checks across both suites:

```bash
make test
```

## Proving the copy on your machine is restorable

Nothing above matters if the bytes on disk are quietly wrong. `verify.sh` is a
fully offline check — it never contacts GitHub, so what it reports is a
statement about your machine and nothing else:

```bash
docker exec gitarchive /usr/local/bin/verify.sh
```

```
SOURCE            REPOS   REFS   PINS       SIZE
alpha                12    310     27    1.2 GiB
artcraft              3     44      0    4.8 GiB

repos      15
refs       354
pinned     27
size       6.0 GiB
digest     sha256:9f2c...
```

It checks four things:

1. every mirror directory still exists
2. `git fsck` finds no missing or broken objects
3. **every commit ever recorded in `pinned.tsv` still resolves** — this is the
   actual promise the archive makes, and fsck cannot check it, because a
   silently deleted unreferenced object leaves a repo that looks perfectly fine
4. a sample of pinned commits can be materialised, blobs and all, so it tests
   restorability rather than mere presence

`--full` validates every object rather than just connectivity, for catching bit
rot. `--drill N` changes the sample size.

The **digest** is a sha256 over every repo's `ref → sha` set. Record it
somewhere outside the NAS once in a while. If you ever need to answer "is what I
have now the same thing I had on the 3rd", the digest settles it without
reading a single file back.

It runs on every nightly pass, and the container healthcheck goes unhealthy
if verification stops happening, because an unverified archive is an
unproven one.

### What this does and does not prove

It proves the archive is **logically** intact: nothing you were promised is
missing, and everything present is readable. It cannot protect against the disk
dying — that is what parity and the off-array bundle copy are for. "Unbreakable"
here means *if the bytes are there, they are restorable, and you can prove it*.

## What missing pushes mean

They mean you do not have those particular states. Nothing else.

- They do **not** corrupt anything. Each fetched commit is self-contained with
  its full tree and ancestry.
- They do **not** break "rolling forward". Fetching is stateless: the next run
  negotiates fresh with the server, and having less local history only changes
  how much it transfers.
- They do **not** chain into later losses. The pinned tips keep everything that
  was ever a branch tip at a fetch boundary, and pins are never removed.

If the final state descends from a state you missed, you usually have it anyway.
Only an *unrelated* rewrite that is never fetched is genuinely absent, and
`restore.sh rescue` can still pull it while upstream retains the object.

This is also why the push-event ledger is optional. It is an audit trail and a
convenience for answering "what happened at 14:32". The safety mechanism is
pinning plus verification. Set `LEDGER_INTERVAL: "0"` to turn it off entirely
without weakening the archive.



## Off-array copy

`bundles/YYYY-MM/` is self-contained; each file is `git bundle verify`-able and
cloneable with no dependency on this container. Sync that tree to an external
drive or object storage monthly. That is the copy that survives the NAS.

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

## Scheduling and bandwidth

The default is one full pass per night at 03:15 local time (`TZ`):

```yaml
SCHEDULE_AT: "03:15"
RUN_ON_STARTUP: "1"     # also run once when the container starts
```

A pass runs, in order: **backup → ledger → bundle → verify**. Bundles are
invoked every night but only do work when `BUNDLE_INTERVAL` has elapsed, because
a bundle is a full standalone copy of the repo and does not deduplicate. Running
them nightly would multiply your storage by thirty.

Bundles are the one thing you should *not* put on the nightly schedule.

### Cost of a pass

Bandwidth is proportional to what changed upstream, not to how often you look.
An unchanged repository costs one ref advertisement — the client compares and
disconnects:

| Component | Cost |
|---|---|
| Refs for an unchanged repo | ~50 bytes per ref, so 2–10 KB typically |
| 100 unchanged repos | ~0.5 MB per pass |
| A day of ordinary commits | 20–200 KB per active repo |
| A big binary push | whatever the binary is |

Polling hourly instead of nightly is 12 MB/day instead of 0.5 MB/day, which is
nothing. The two things that actually scale with frequency are not bytes:

- **API requests.** The ledger is one call per repo per poll. 100 repos at 15
  minutes is 9,600 requests/day; nightly is 100.
- **Tag-heavy and LFS repos.** Ref advertisement grows with ref count, so a
  repo with thousands of tags pays ~300 KB *per fetch* whether or not anything
  changed, and `git lfs fetch --all` re-lists objects every run.

What nightly actually costs is **granularity**: an intermediate state created
*and* abandoned between two runs may never be fetched. That does not affect
rolling back to a good state — the state that was current at the previous run
gets pinned when the next one sees the damage. It only means `restore.sh rescue`
becomes a tool you might actually use.

### Other modes

```yaml
SCHEDULE_AT: ""          # fall back to the interval knobs below
```

```bash
docker exec gitarchive /usr/local/bin/entrypoint.sh verify    # one job
docker exec -e ONE_PASS=1 gitarchive /usr/local/bin/entrypoint.sh loop
```

or hand it to Unraid's User Scripts / cron and keep the container idle.

## Knobs

| Variable | Default | Meaning |
|---|---|---|
| `GITHUB_RO_TOKENS` | — | one or more read-only PATs |
| `PUBLIC_REPOS` | — | `owner/repo` list to archive |
| `PUBLIC_ACCOUNTS` | — | owners to enumerate publicly |
| `BRANCH_POLICY` | `all` | `all`, `default`, or `main,release/*` |
| `SCHEDULE_AT` | `03:15` | nightly wall-clock time; empty enables interval mode |
| `RUN_ON_STARTUP` | `1` | run a full pass when the container starts |
| `LEDGER_INTERVAL` | `900` | event poll seconds; `0` disables the ledger |
| `BUNDLE_INTERVAL` | `2592000` | seconds between bundle + repack |
| `BUNDLE_KEEP` | `6` | bundle generations retained |
| `BACKUP_INTERVAL` | `3600` | interval mode only |
| `VERIFY_INTERVAL` | `604800` | interval mode only |
| `CONFIG_FILE` | `/config/config.json` | optional per-source policies |

## Limitations

- **Issues, PRs, release assets and wikis are not in git.** Code and history
  only. Run `josegonzalez/python-github-backup` alongside for the API side.
- Submodule contents are not fetched, only the pointer commits.
- **Bundles do not contain LFS objects.** `git bundle` only carries git
  objects, so for an LFS repo the monthly bundle is history-only; the LFS
  objects exist solely in `mirrors/<owner>/<repo>.git/lfs`. If you rely on LFS
  and need the off-array copy to be complete, handle that directory separately.
- A commit pushed and force-pushed away inside one interval is never fetched.
  The ledger records the SHA, actor and time, and `restore.sh rescue` can pull
  it back from upstream while upstream still holds it. Once upstream has
  collected it, that commit is genuinely gone.
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
make test     # 135 checks, no network, no Docker (unit + adversarial)
make build
```

The suite drives the real scripts against local bare repositories with a fake
API. It asserts the properties that matter directly: pinned commits survive
`git gc --prune=now`, a deleted repo is retired rather than removed, an API
outage still backs up from the known list, a missing mirror is reported, and the
three branch policies select the right refs.
