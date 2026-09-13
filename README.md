# truenas-identity-toolkit

Back up, document, and migrate local users and groups on TrueNAS SCALE -
over SSH and `midclt`, never the deprecated REST API.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Shell](https://img.shields.io/badge/bash-4%2B-89e051.svg)
![Platform](https://img.shields.io/badge/platform-TrueNAS%20SCALE-0095d5.svg)

## What it does

- **Daily documentation**: pull local users/groups from a live SCALE
  system over SSH+`midclt`, save a versioned JSON backup, and generate a
  self-contained HTML report plus a Markdown report for offline reading.
- **Migration extraction**: pull users, groups, *and password hashes*
  straight out of a TrueNAS config backup file (`.db` or the UI's `.tar`
  download) - something the live API can never expose.
- **Migration restore**: recreate those users/groups on a target SCALE
  system, with interactive conflict resolution, configurable
  home-directory remapping, and shell-fallback substitution.
- **Inspection**: sanity-check a config backup's structure (tables,
  columns, row counts, hash presence/absence - never values) before
  trusting it.

## What it does NOT do

- **No TrueNAS CORE / FreeBSD support.** SCALE only.
- **No full system/config restore.** Only local users and groups - not
  pools, shares, ACLs, apps, network, or anything else in the config
  database.
- **No cluster support.** One target host per run.
- **No REST API usage**, ever - `/api/v2.0` is deprecated in SCALE 25.04
  and scheduled for removal; every live-system call goes through SSH +
  `midclt` instead (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **No password *hash* restoration.** There is currently no documented,
  supported `midclt` method to set a user's password from a raw hash;
  see ARCHITECTURE.md for what was investigated. New accounts get an
  interactive temp-password/disable/lock/skip prompt instead.

## Requirements

**On the machine you run the toolkit from** (Linux, macOS, or WSL/Git
Bash on Windows):

- Bash 4+
- `jq`
- `ssh`
- `sqlite3` (only needed for `backup-db.sh` / `inspect-config-db.sh`)

**On every TrueNAS SCALE system involved** (source and target):

- SSH access (key-based recommended) as `root` or another account with
  equivalent middleware access
- Nothing else - `midclt` ships with SCALE itself

## Quickstart

**Daily backup + report from a live system:**

```bash
./bin/backup-api.sh --host truenas.lan --identity ~/.ssh/id_ed25519
# -> ./backups/truenas.lan-<timestamp>/{backup.json,report.html,report.md}
```

**Migrating between two SCALE boxes** (see
[docs/MIGRATION.md](docs/MIGRATION.md) for the full walkthrough):

```bash
# 1. Extract users/groups/hashes from a downloaded config backup
./bin/backup-db.sh --input ./truenas1-config.tar --output-dir ./backups/migration1

# 2. Dry-run the restore against the new system
./bin/restore.sh --input ./backups/migration1/backup.json \
    --target-host truenas2.lan --home-strategy skip --dry-run

# 3. Run it for real
./bin/restore.sh --input ./backups/migration1/backup.json \
    --target-host truenas2.lan --home-strategy skip
```

**Inspecting a config backup before trusting it:**

```bash
./bin/inspect-config-db.sh --input ./truenas1-config.tar
```

## Command reference

### `bin/backup-api.sh`

Back up local users/groups from a **live** system over SSH+`midclt`.

| Flag | Default | Description |
|---|---|---|
| `--host <host>` | *(required)* | Target TrueNAS SCALE host |
| `--user <ssh-user>` | `root` | SSH user |
| `--port <ssh-port>` | `22` | SSH port |
| `--identity <path>` | - | SSH private key |
| `--output-dir <path>` | `./backups/<host>-<UTC-ts>/` | Output directory |
| `--include-builtin` | off | Include builtin users/groups |
| `--no-report` | off | Skip HTML/Markdown report generation |
| `--dry-run` | off | Fetch and print counts only; write nothing |
| `--yes` | off | Assume yes on prompts |
| `--no-color` | off | Disable colored output |
| `-h, --help` / `-v, --version` | | |

### `bin/backup-db.sh`

Extract users/groups/**hashes** from a config backup file (`.db` or `.tar`).

| Flag | Default | Description |
|---|---|---|
| `--input <path>` | *(required)* | `freenas-v1.db` or a config `.tar` |
| `--output-dir <path>` | `./backups/from-db-<UTC-ts>/` | Output directory |
| `--include-builtin` | off | Include builtin users/groups |
| `--no-report` | off | Skip HTML/Markdown report generation |
| `--yes` / `--no-color` / `-h` / `-v` | | |

Output `backup.json` is `chmod 600` whenever it contains hashes. Reports
never render hash values, only `<hash-present>` / `<hash-absent>`.

### `bin/inspect-config-db.sh`

Read-only diagnostic for a config backup file - format, SQLite integrity,
table/column layout, non-builtin counts, hash presence/absence.

| Flag | Default | Description |
|---|---|---|
| `--input <path>` | *(required)* | `freenas-v1.db` or a config `.tar` |
| `--no-color` / `-h` / `-v` | | |

### `bin/restore.sh`

Restore a backup JSON onto a target system over SSH+`midclt`.

| Flag | Default | Description |
|---|---|---|
| `--input <path>` | *(required)* | Backup JSON |
| `--target-host <host>` | *(required)* | Target TrueNAS SCALE host |
| `--target-user <ssh-user>` | `root` | SSH user |
| `--target-port <ssh-port>` | `22` | SSH port |
| `--target-identity <path>` | - | SSH private key |
| `--config <path>` | - | `restore.conf` with policy defaults (see `examples/`) |
| `--home-strategy <mode>` | `skip` | `skip` \| `remap` \| `preserve` \| `prompt` |
| `--home-remap <FROM>=<TO>` | - | Prefix remap rule (repeatable) |
| `--shell-fallback <path>` | `/usr/bin/bash` | Shell substituted when the backup's is missing on target |
| `--output-dir <path>` | `./restore-logs/<host>-<UTC-ts>/` | Where `restore.log` is written |
| `--dry-run` | off | Show planned operations; make no changes |
| `--yes-to-all-conflicts <mode>` | - | `skip` \| `overwrite` - resolve every conflict the same way |
| `--yes` | off | Assume yes on confirmation prompts |
| `--no-color` / `-h` / `-v` | | |

### `bin/reset-users.sh`

**Destructive.** Deletes all non-builtin users (test-cycle helper only).

| Flag | Default | Description |
|---|---|---|
| `--host <host>` | *(required)* | Target TrueNAS SCALE host |
| `--i-understand-this-is-destructive` | *(required)* | Mandatory acknowledgment |
| `--user <ssh-user>` | `root` | SSH user |
| `--port <ssh-port>` | `22` | SSH port |
| `--identity <path>` | - | SSH private key |
| `--delete-primary-groups` | off | Also delete now-orphaned primary groups |
| `--production-hosts <regex>` | - | Extra refusal pattern (always refuses `prod`/`production`) |
| `--dry-run` | off | Show what would be deleted; delete nothing |
| `--yes` / `--no-color` / `-h` / `-v` | | |

## Security notes

- **Password hashes**: only ever present in output from `backup-db.sh`
  (`contains_hashes: true`). The JSON file is `chmod 600` in that case.
  Generated reports never render a hash value - only
  `<hash-present>` / `<hash-absent>`.
- **SSH keys**: key-based auth is the default assumption throughout
  (`--identity`); the toolkit never prompts for or stores an SSH
  password.
- **restore.conf**: excluded from version control by `.gitignore` - copy
  `examples/restore.conf.example` rather than committing your own.
  It is parsed by a restricted `KEY=VALUE` reader, never `source`d as
  bash, so a config file cannot execute arbitrary code.
- **Config backups** (`.db`/`.tar`) and everything under `backups/` are
  also excluded from version control - they may contain real account
  data and hashes.

## Design decisions

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the reasoning behind
SSH+`midclt` over the REST API, JSON over CSV, name-based (not uid/gid)
matching, the `skip` home-directory default, per-conflict prompting with
an "apply to all" memory, and the password-hash restoration investigation.

## License

MIT - see [LICENSE](LICENSE).

## Author

Eng. Ahmad Abd Al-Hadi
