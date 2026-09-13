# Architecture and design decisions

This document explains the *why* behind the toolkit, not the *how* (see the
script `--help` output and [FIELD-REFERENCE.md](FIELD-REFERENCE.md) for
that). It exists so a future maintainer - including a future version of the
author - doesn't have to reverse-engineer the reasoning from the code.

## Why SSH + midclt, never the REST API

TrueNAS SCALE exposes the same functionality through three surfaces: the
WebUI, the `/api/v2.0` REST API, and `midclt` (the "middleware client",
which talks the middleware's native WebSocket JSON-RPC protocol - the same
one the WebUI itself uses). As of SCALE 25.04 ("Fangtooth"), iXsystems has
marked the REST API as deprecated with a stated intent to remove it in a
future release, in favor of the WebSocket API that `midclt` wraps.

This toolkit is explicitly meant to survive future SCALE releases, so every
live-system operation goes through `ssh <target> "midclt call <method>
<json-args>"` (see `lib/transport.sh`). This has three consequences worth
knowing:

- No HTTPS/API-key setup is required on the target - only SSH access,
  which every TrueNAS SCALE box already has.
- `midclt`'s method surface (`user.query`, `user.create`, `group.query`,
  `system.info`, ...) is the same surface documented in the "middleware"
  API docs and used internally by the WebUI, so it is the least likely
  interface to disappear.
- The cost is one SSH round-trip per `midclt` call, which is irrelevant at
  the scale (tens to low hundreds of local accounts) this toolkit targets.

## Why JSON, never CSV

The original brief for this class of tool used CSV. This rewrite drops it
entirely:

- Several fields are inherently structured (`sudo_commands` is a list,
  `attributes` is an object, group membership is a list of IDs). CSV forces
  either flattening (lossy, hard to restore correctly) or an escaping
  scheme nobody agrees on for embedded commas/quotes.
- `jq` makes JSON as easy to slice and filter from bash as CSV ever was,
  without inventing a delimiter convention.
- The backup file is also the migration artifact for `restore.sh` - it
  needs to round-trip perfectly, including `null` vs `false` vs `""`
  distinctions that CSV cannot represent unambiguously.

Reports (HTML/Markdown) exist precisely so a human never has to read the
JSON directly; the JSON itself is only ever machine-consumed.

## Why groups and users are matched by name, never by uid/gid

`restore.sh` looks up whether a backup's user or group already exists on
the target by **name**, not by uid/gid. Two systems that were never meant
to be identical (which is the normal case for a migration) will very
often have accumulated different uid/gid assignments for logically-the-same
account - e.g. a rebuilt system where accounts were recreated in a
different order. Matching by uid/gid in that situation would either create
a duplicate account under a different uid, or silently overwrite an
unrelated account that happens to occupy the same numeric id. Matching by
name is what a human operator would do by inspection, and it is what the
pre-flight report explicitly flags as a "conflict" when the uid/gid
*disagrees* for a name that does match - surfacing the mismatch instead of
hiding it.

The numeric uid/gid from the backup is still what gets requested when
*creating* a new account, so identity (e.g. for NFS, which cares about
numeric ids) is preserved whenever the target doesn't already have a
conflicting assignment.

## Why `--home-strategy skip` is the default

Home directories live on a pool/dataset layout that is essentially never
identical between two systems, even two SCALE boxes from the same operator
- pool names, mountpoints, and dataset structure are chosen per-system.
Defaulting to `preserve` (send the backup's exact path) would silently
create user accounts pointing at home directories that don't exist on the
new system, `home_create` notwithstanding, since the *parent* dataset
frequently doesn't exist either.

`skip` (pass no `home` and `home_create=false`, deferring to whatever
TrueNAS's own default is) is the only strategy that can never point a new
account at a nonexistent or wrong location. `remap` and `preserve` are
there for the common case where the operator *does* know the equivalent
path on the new system (see `examples/restore.conf.example`), and `prompt`
covers the rest interactively. This was also the explicit preference of
the toolkit's author (Ahmad) during design.

## Why conflicts are resolved per-entity with an "apply to all" memory

A migration of even a modest number of accounts can produce several
conflicts (accounts that already exist on the target with different
attributes). Prompting for every single one with no way to generalize the
answer is exhausting and error-prone (the temptation to blindly mash
"enter" grows with each prompt); silently picking one policy for *all*
conflicts up front removes the operator's ability to handle an unusual one
differently. `lib/conflict.sh` splits the difference: the first conflict
is always shown in full (backup vs. target, with a `[d]iff` option), and
only *after* an explicit choice does the operator get asked whether to
apply that choice to everything remaining. `--yes-to-all-conflicts` exists
for scripted/CI-style runs where even that first prompt should be skipped.

## Password / hash restoration: what was investigated, and why it isn't done

The specification asked for `restore.sh` to restore password hashes when
`backup-db.sh` provides them, "using the current SCALE method for setting
a user's password hash without knowing the plaintext" if one exists.

What was investigated:

- `midclt`'s `user.create` / `user.update` accept a `password` argument,
  but its documented and actual behavior is that it takes **plaintext**,
  which the middleware hashes server-side (via PAM/`crypt`) when applying
  it. There is no public, documented parameter on either method (in any
  currently supported SCALE release) that accepts a pre-computed
  `unixhash` or `smbhash` and installs it directly.
- `midclt call core.get_methods '["user.update"]'` (middleware's own
  method-schema introspection - the same reflection mechanism
  `backup-db.sh` draws inspiration from for its own DB introspection) does
  not, on any currently supported release, advertise such a field on the
  public schema.
- The only way to set a raw hash directly is to write it into
  `account_bsdusers` in `freenas-v1.db` directly - i.e. exactly the kind
  of direct-database-write the spec calls "a last resort." This toolkit
  deliberately does **not** implement that: writing to the live
  middleware's SQLite database out from under a running `midclt`/
  `django`-based service risks corruption or a change that never takes
  effect until a service restart the tool can't safely trigger for you,
  and doing it correctly depends on schema details that (as documented in
  `backup-db.sh`) already shift between releases. An operator who accepts
  that risk can still do it by hand; this tool won't do it silently on
  their behalf.

Conclusion: there is currently no safe, supported way to migrate a
password *hash* through `midclt`. `restore.sh` therefore treats every
newly-created user the same way regardless of backup source
(`api` or `config-db`): an interactive prompt to set a temporary
plaintext password, disable the password, lock the account, or skip the
user. This is exactly the "fall back to the API-mode password prompt"
behavior the spec calls for when hash restoration isn't possible. If a
future SCALE release adds a supported hash-import mechanism,
`resolve_password_action()` in `restore.sh` is the single place that would
need to change.

## Runtime schema introspection in backup-db.sh

`account_bsdusers` / `account_bsdgroups` column names (the `bsdusr_*` /
`bsdgrp_*` prefixes) have not been stable across SCALE/FreeNAS releases,
and the exact name of the many-to-many group-membership join table is not
guaranteed either. `backup-db.sh` and `inspect-config-db.sh` therefore
never hardcode a column list: they query `sqlite_master` for the table
names and `PRAGMA table_info(...)` for the column names at run time, and
pick the best matching candidate for each canonical field (e.g. a group's
display name is looked for as `bsdgrp_group` first, since that has been
the more common historical name, then `bsdgrp_name`). A canonical field
whose column can't be found is logged as a warning and left `null` in the
output rather than aborting the whole extraction - only the truly
load-bearing columns (a uid and a username column existing at all) are
treated as fatal if missing.

Two heuristics are used where the schema doesn't give a definitive answer,
and both are best-effort:

- **builtin detection**: if a `bsdusr_builtin` / `bsdgrp_builtin` column
  exists, it is used directly; otherwise an account/group is treated as
  "builtin" when its uid/gid is below 1000, mirroring the common Unix
  convention TrueNAS itself follows for locally-created accounts.
- **membership table detection**: the first table matching
  `account_bsdgroupmembership` (case-insensitively) is used; failing that,
  any table whose name matches `bsd.*group.*member` or
  `bsdusers.*bsdgroups`. If nothing matches, auxiliary group memberships
  are left empty (primary group only) with a warning - this is safer than
  guessing at a join table that turns out to be unrelated.

`inspect-config-db.sh` exists specifically so an operator can check what a
given config backup's actual schema looks like *before* trusting
`backup-db.sh`'s introspection on it.

## Known limitations

- **Match detection is by identity field only.** A user is reported as
  "already present and matching" purely by uid equality (a group, by gid
  equality); other attributes (shell, home, sudo commands, SMB flag, ...)
  are not diffed for the purpose of deciding whether something counts as
  a conflict. This keeps the pre-flight report and conflict flow simple
  and matches the spec's own example (which frames a conflict around
  uid/shell/home together, prompting the operator rather than trying to
  auto-resolve field-by-field). An operator who needs to confirm every
  attribute matches should compare the two systems' reports directly.
- **Rename-on-conflict** appends `_restored` to the name (and does not
  currently probe for further collisions beyond that single suffix).
- **New primary groups** are created via TrueNAS's `group_create: true`
  flag on `user.create` when the backup's primary group name isn't found
  on the target, which (per documented `midclt` behavior) creates a new
  same-named group automatically; this could not be verified against a
  live system while building this toolkit and should be treated as
  best-effort until confirmed in your environment.
- **GID/UID collisions against a different-named entity** (the backup
  wants gid 3001 for `engineering`, but the target already has an
  unrelated group at gid 3001) are not auto-resolved; `midclt` will
  reject the creation, and `restore.sh` reports it as a failure rather
  than silently reassigning either side's id.
