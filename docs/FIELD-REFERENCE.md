# Field reference

This document is the authoritative description of the backup JSON schema:
every field, where it comes from in each backup mode, and what `restore.sh`
does with it. `lib/schema.sh` enforces the structural parts of this (the
top-level fields and the two required per-entity fields); this document
covers the rest.

## Top-level document (schema version 1)

| Field | Type | Description |
|---|---|---|
| `schema` | integer | Schema version. Currently always `1`. `restore.sh` refuses a file with an unrecognized or older version rather than guessing. |
| `generated_at` | string | ISO-8601 UTC timestamp of when the backup was produced. |
| `source` | string | `"api"` (from `backup-api.sh`, over SSH+midclt) or `"config-db"` (from `backup-db.sh`, from a config backup file). |
| `source_host` | string | The live system's hostname (`api`), or the input filename (`config-db` - a config DB has no notion of "its own hostname" independent of the live system it came from). |
| `source_version` | string | The SCALE version string from `system.info` (`api`), or `"unknown"` (`config-db` - not derivable from the account tables alone). |
| `tool_version` | string | The toolkit version that produced the file. |
| `contains_hashes` | boolean | `true` only for `config-db` backups where at least one user had a non-empty `unixhash` or `smbhash`. |
| `hash_warning` | string | Present only when `contains_hashes` is `true`. Human-readable reminder that the file contains hashes and is chmod 600. |
| `groups` | array | See below. |
| `users` | array | See below. |

## Group object

| Field | Type | `api` source | `config-db` source | Restore behavior |
|---|---|---|---|---|
| `id` | integer/null | `user.query`/`group.query`'s internal `id` | the DB row's own primary key | Not used for matching (see `docs/ARCHITECTURE.md` - matching is by name). Never sent to `group.create`/`group.update`. |
| `gid` | integer | `group.query` | `bsdgrp_gid` (or `gid`) | Sent as-is when creating a new group. When the group already exists by name with a different gid, this is exactly what triggers the conflict prompt. |
| `name` | string | `group.query` | `bsdgrp_group`, falling back to `bsdgrp_name`/`bsdgrp_groupname`/`name` | The match key. Must be present; a group missing this is dropped with a warning during extraction. |
| `sudo_commands` | array of strings | `group.query` | `bsdgrp_sudo_commands` (stored as a JSON-encoded string in the DB; parsed back into an array) | Passed through unchanged on create/update. |
| `sudo_commands_nopasswd` | array of strings | `group.query` | `bsdgrp_sudo_commands_nopasswd` | Same as above. |
| `smb` | boolean | `group.query` | `bsdgrp_smb` | Passed through on create; not currently changed on update (only `gid` is updated for an "overwrite" conflict resolution - see Known limitations in ARCHITECTURE.md). |
| `users` | array of integers | `group.query`'s member id list | the membership join table, if found (raw ids, not resolved to anything) | Informational only in reports; not used to reconstruct membership during restore (membership is driven from the *user* side - see the user's `groups` field below). |

## User object

| Field | Type | `api` source | `config-db` source | Restore behavior |
|---|---|---|---|---|
| `id` | integer/null | `user.query`'s internal `id` | the DB row's own primary key | Not used for matching. |
| `uid` | integer | `user.query` | `bsdusr_uid` | The match key's companion: a name match with a different `uid` is a conflict. Sent to `user.create` for a new account. |
| `username` | string | `user.query` | `bsdusr_username` | The match key. Must be present. |
| `full_name` | string | `user.query` | `bsdusr_full_name` | Passed through. |
| `email` | string/null | `user.query` | `bsdusr_email` | Passed through when non-empty. |
| `group_gid` | integer/null | resolved from `user.query`'s embedded `group.bsdgrp_gid` | resolved via the user's `bsdusr_group_id` foreign key against the extracted groups | Informational (paired with `group_name`, which is what restore actually uses). |
| `group_name` | string/null | resolved from `user.query`'s embedded `group.bsdgrp_group` | same FK resolution as `group_gid` | Primary group on the target is resolved by looking up this name; if not found, TrueNAS is asked to auto-create a same-named group (`group_create: true`). |
| `groups` | array of integers | `user.query`'s auxiliary group id list (gids on the *source* system) | resolved via the membership join table, expressed as **gids** (matching the `api` shape) | Each backup gid is mapped to a name using the backup's own `groups` array, then that name is resolved to an id on the *target* - never applied as a raw id, since source and target ids/gids are not assumed to correspond. |
| `home` | string/null | `user.query` | `bsdusr_home` | Subject to `--home-strategy` (see ARCHITECTURE.md and `examples/restore.conf.example`). |
| `shell` | string/null | `user.query` | `bsdusr_shell` | Checked for existence on the target (`test -x`); substituted with `--shell-fallback` if missing. |
| `locked` | boolean | `user.query` | `bsdusr_locked` (SQLite integer 0/1, coerced to a real boolean) | Passed through on create/update. |
| `password_disabled` | boolean | `user.query` | `bsdusr_password_disabled` (coerced) | Informational for existing accounts; for a *new* account, the actual password field sent is decided by the interactive prompt in `restore.sh`, not copied from this value. |
| `smb` | boolean | `user.query` | `bsdusr_smb` (coerced) | Passed through. |
| `sudo_commands` | array of strings | `user.query` | `bsdusr_sudo_commands` (JSON-encoded string, parsed) | Passed through. |
| `sudo_commands_nopasswd` | array of strings | `user.query` | `bsdusr_sudo_commands_nopasswd` | Passed through. |
| `sshpubkey` | string/null | `user.query` | `bsdusr_sshpubkey` | Passed through when non-empty. |
| `immutable` | boolean | `user.query` | `bsdusr_immutable` (coerced) | Informational only; not currently sent to `user.create`/`user.update` (TrueNAS manages this flag itself for certain system accounts). |
| `twofactor_auth_configured` | boolean | `user.query` | always `false` (not derivable from the config DB) | Informational only. |
| `attributes` | object | `user.query` | always `{}` (not derivable from the config DB) | Informational only. |
| `hashes` | object | **absent** (`user.query` never exposes these) | `{unixhash, smbhash}` from `bsdusr_unixhash` / `bsdusr_smbhash` | Never restored directly - see "Password / hash restoration" in ARCHITECTURE.md. Never rendered by reports; only presence/absence is shown as `<hash-present>` / `<hash-absent>`. |

### Hash formats (when present)

- `unixhash`: standard Linux SHA-512 crypt, `$6$<salt>$<hash>`.
- `smbhash`: Samba NT hash line format,
  `username:uid:LMHASH:NTHASH:[flags]:LCT-timestamp:`.

## Fields intentionally *not* captured

- Any REST-API-only representation of a user/group (this toolkit never
  calls the REST API - see ARCHITECTURE.md).
- Group quotas, dataset ACLs, or anything outside the account tables
  themselves - this toolkit's scope is local users and groups only, not a
  full system/config restore.
- The TrueNAS "secret seed" (used for password-related cryptographic
  operations at the system level) - irrelevant to per-account hash/attribute
  extraction and not read by `backup-db.sh`.
