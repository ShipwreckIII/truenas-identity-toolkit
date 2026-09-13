# Migration guide: moving local users/groups between two SCALE systems

This walks through a full SCALE-to-SCALE migration: you're retiring
`truenas1` and want its local users, groups, and passwords to exist on a
freshly-installed `truenas2`, without restoring `truenas2`'s entire system
configuration from `truenas1`'s backup.

This toolkit only handles **local users and groups**. It does not touch
pools, shares, permissions/ACLs, apps, or any other part of system
configuration.

## 0. Prerequisites

- SSH access (key-based recommended) to both systems as a user that can
  run `midclt` - in practice, `root`, or another account with equivalent
  middleware access.
- `jq` and `sqlite3` installed on the machine you run the toolkit from
  (not on the TrueNAS systems themselves - those are only ever reached
  over SSH).
- A config backup file from `truenas1`: **System Settings → General →
  Manage Configuration → Save Config** in the WebUI. Either the raw
  `.db` it contains or the downloaded `.tar` works directly with
  `backup-db.sh`.

## 1. Sanity-check the config backup

Before trusting anything, inspect the file you downloaded:

```bash
./bin/inspect-config-db.sh --input ./truenas1-config-20260101.tar
```

This prints the detected format, a SQLite integrity check, every table's
row count, the actual column names in `account_bsdusers` /
`account_bsdgroups` (these vary across SCALE versions - see
`docs/ARCHITECTURE.md`), and a non-builtin user/group count. It never
prints a hash value, only whether one is present. If this doesn't look
like what you expect - wrong table names, zero non-builtin users - stop
here and get a fresh config backup before continuing.

## 2. Extract users, groups, and password hashes

```bash
./bin/backup-db.sh \
  --input ./truenas1-config-20260101.tar \
  --output-dir ./backups/truenas1-migration
```

This writes `./backups/truenas1-migration/backup.json` (chmod 600, since
it contains password hashes), plus `report.html` and `report.md` for a
quick human review (hash values are never rendered in either report -
only `<hash-present>` / `<hash-absent>`).

Open `report.html` and check the user/group lists look complete and
correct before proceeding. If you don't need password migration at all
(e.g. you're fine setting new passwords), you can use
`bin/backup-api.sh --host truenas1 ...` against the *live* system instead
- simpler, but it cannot capture hashes (`user.query` never exposes them;
that's the entire reason `backup-db.sh` exists).

## 3. Decide your home-directory policy

Home directories almost never live at the same path on two different
systems (different pool names, different dataset layout). Figure out the
mapping now:

- If `truenas1`'s homes were under `/mnt/tank/home/...` and `truenas2`'s
  equivalent pool is `/mnt/newpool/home/...`, you'll use
  `--home-strategy remap` with `--home-remap /mnt/tank/home=/mnt/newpool/home`.
- If you'd rather not deal with it at all and let TrueNAS assign defaults,
  do nothing - `skip` is the default strategy.

Copy `examples/restore.conf.example` if you'd rather set this (and other
policy options) once in a file than repeat flags every run:

```bash
cp examples/restore.conf.example ./restore.conf
# edit HOME_STRATEGY / HOME_REMAP / SHELL_FALLBACK as needed
```

## 4. Dry-run the restore

Always dry-run first. This connects to `truenas2`, fetches its current
users/groups, and prints exactly what would be created/skipped/flagged as
a conflict - without changing anything:

```bash
./bin/restore.sh \
  --input ./backups/truenas1-migration/backup.json \
  --target-host truenas2 \
  --config ./restore.conf \
  --dry-run
```

Read the pre-flight report carefully:

- `[create]` entries are new accounts/groups - check the uid/gid ranges
  make sense for your target system.
- `[conflict]` entries already exist on `truenas2` under the same name
  with a *different* uid/gid - decide up front whether you expect that
  (e.g. `truenas2` already has an unrelated account with that name) or
  whether it's actually the same person/service and should be
  overwritten.
- `warn:` lines under a user flag a home parent directory or shell that
  doesn't exist yet on the target - not fatal, but worth fixing first if
  it's unexpected (e.g. create the target dataset before proceeding).

## 5. Run the real restore

Drop `--dry-run`. You'll be asked to confirm once after the pre-flight
report, then walked through any conflicts and password decisions
interactively:

```bash
./bin/restore.sh \
  --input ./backups/truenas1-migration/backup.json \
  --target-host truenas2 \
  --config ./restore.conf
```

For every newly-created account, you'll be asked how to handle its
password - **hashes are never restored directly**; see "Password / hash
restoration" in `docs/ARCHITECTURE.md` for why. Your options per user:

- `[t]emp-password` - set a plaintext temporary password the user should
  change on first login.
- `[d]isable-password` - account exists, but no password-based login
  (typical for a service account, or if you'll set a password another
  way afterward).
- `[l]ock-account` - password disabled *and* locked; nothing can log in
  as this account until you explicitly unlock it.
- `[s]kip-user` - don't create this account at all.

For any conflicts (a name that already exists on `truenas2` with
different attributes), you'll see the same per-conflict prompt as the
dry-run's pre-flight report described, but now with the ability to
`[s]kip` / `[o]verwrite` / `[r]ename-source` / `[d]iff` / `[a]bort`, and
to apply your first answer to every remaining conflict.

## 6. Verify

Re-run `backup-api.sh` against `truenas2` and compare its `report.html`
against `truenas1`'s from step 2. Check that:

- Every user you expected exists, with the right uid, shell, and group
  memberships.
- SMB-enabled users have `smb: true` if they need Samba access - shares
  will not work for them otherwise.
- Sudo commands made it across for any admin/service accounts that need
  them.

## Iterating on a test system

If you're rehearsing this migration against a disposable lab TrueNAS box
before doing it for real, `bin/reset-users.sh` lets you wipe all
non-builtin users between attempts instead of reinstalling SCALE each
time:

```bash
./bin/reset-users.sh --host lab-truenas.local --i-understand-this-is-destructive
```

It refuses to run against anything with "prod"/"production" in its
hostname, prints the full deletion list, requires you to type the
hostname to confirm, and gives you a 10-second countdown before deleting
anything. See `bin/reset-users.sh --help` for the full safety-gate list.
**Never point this at a system you care about.**
