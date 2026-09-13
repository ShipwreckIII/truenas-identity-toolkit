# Changelog

All notable changes to this project are documented in this file.

## [0.1.0] - 2026-09-13

Initial release. TrueNAS SCALE only; SSH+`midclt` transport only (no REST
API); JSON as the sole backup format (no CSV).

### Added

- `bin/backup-api.sh` - back up non-builtin local users/groups from a live
  SCALE system over SSH+`midclt`, writing a schema-v1 JSON backup plus
  HTML and Markdown reports.
- `bin/backup-db.sh` - extract users, groups, and password hashes
  (`unixhash`/`smbhash`) from a TrueNAS config backup file (raw
  `freenas-v1.db` or the WebUI's `.tar` download), via runtime SQLite
  schema introspection rather than hardcoded column names. Output is
  `chmod 600` whenever hashes are present.
- `bin/inspect-config-db.sh` - read-only diagnostic for a config backup:
  detected format, SQLite integrity, table/column layout, non-builtin
  account counts, and hash presence/absence (never values).
- `bin/restore.sh` - restore a backup JSON onto a target SCALE system:
  groups before users, matched by name (not uid/gid), with a pre-flight
  report, per-conflict resolution with an "apply to all" memory,
  configurable home-directory strategy (`skip`/`remap`/`preserve`/`prompt`),
  shell-fallback substitution, and an interactive password decision
  (temp-password/disable/lock/skip) for every new account - hash-based
  password restoration is not implemented; see `docs/ARCHITECTURE.md` for
  why.
- `bin/reset-users.sh` - destructive test-cycle helper that deletes all
  non-builtin users on a target, gated behind a required acknowledgment
  flag, a production-hostname refusal check, a printed deletion list, a
  typed hostname confirmation, and a 10-second countdown.
- `lib/common.sh`, `lib/transport.sh`, `lib/schema.sh`, `lib/conflict.sh`,
  `lib/policy.sh`, `lib/report.sh` - shared logging/prompts/exit-code
  conventions, the SSH+`midclt` transport abstraction, backup JSON schema
  versioning/validation, per-conflict prompting, home/shell resolution
  policy, and HTML/Markdown report generation.
- `docs/ARCHITECTURE.md`, `docs/MIGRATION.md`, `docs/FIELD-REFERENCE.md`,
  `examples/restore.conf.example`, `examples/sample-backup.json`.

### Fixed during development

Several issues were caught by testing each script as it was built (against
a synthetic SQLite fixture and a mocked SSH/`midclt` transport, since no
live TrueNAS system was available in the build environment) rather than
shipped untested:

- Bash 5.2+'s `patsub_replacement` shell option makes a literal `&` in the
  replacement side of `${var//pattern/replacement}` act like a sed
  back-reference, silently corrupting any report field containing `&`.
  Disabled globally in `lib/common.sh`.
- An `EXIT` trap whose own last command could fail (`cleanup_tempdirs`)
  was silently overriding every script's real exit code, including
  `--help`/`--version` always reporting exit 1.
- Under `set -o pipefail`, a `grep` that legitimately finds no match (the
  normal "column/table not found" case both DB scripts are supposed to
  handle gracefully) made the enclosing pipeline's assignment trip
  `set -e` and kill the script before the intended fallback logic ever
  ran. Fixed throughout `backup-db.sh` and `inspect-config-db.sh`.
- Functions communicating a result through a global variable
  (`lib/policy.sh`'s remap-matched flag, `lib/conflict.sh`'s "apply to
  all" memory) must never be invoked via command substitution
  (`x="$(fn ...)"`), which runs them in a subshell and silently discards
  the global. Both were switched to a documented plain-global convention.
- SQLite has no native boolean type; `backup-db.sh` was coercing
  `0`/`1` integers to real JSON booleans incorrectly (`0 // false`
  evaluates to `0` in jq, not `false`) before an explicit fix.
