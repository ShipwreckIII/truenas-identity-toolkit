#!/usr/bin/env bash
# backup-api.sh - Connect to a running TrueNAS SCALE system over SSH+midclt
# and save all non-builtin local users and groups to a versioned JSON file,
# plus optional HTML and Markdown reports.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/transport.sh
source "$LIB_DIR/transport.sh"
# shellcheck source=lib/schema.sh
source "$LIB_DIR/schema.sh"
# shellcheck source=lib/report.sh
source "$LIB_DIR/report.sh"

trap cleanup_tempdirs EXIT

readonly PROG_NAME="backup-api.sh"

# usage: prints help text. Arguments: none.
usage() {
    cat <<EOF
$PROG_NAME - Back up local users/groups from a live TrueNAS SCALE system.

Connects over SSH and drives 'midclt' remotely (never the REST API, which is
deprecated in SCALE). Note: 'user.query' does not expose password hashes; use
backup-db.sh against a config backup file if you need hashes for migration.

Usage:
  $PROG_NAME --host <host> [options]

Required:
  --host <hostname-or-ip>       Target TrueNAS SCALE host

Options:
  --user <ssh-user>             SSH user (default: root)
  --port <ssh-port>             SSH port (default: 22)
  --identity <ssh-key-path>     SSH private key to use
  --output-dir <path>           Output directory
                                 (default: ./backups/<host>-<UTC-timestamp>/)
  --include-builtin             Include builtin users/groups (default: off)
  --no-report                   Skip HTML/Markdown report generation
  --dry-run                     Fetch and print counts only; write nothing
  --yes                         Assume yes on all confirmation prompts
  --no-color                    Disable colored output
  -h, --help                    Show this help and exit
  -v, --version                 Show version and exit

Exit codes:
  0 success   1 general error   2 invalid arguments   3 connectivity failure
  4 validation failure          5 partial success

Example:
  $PROG_NAME --host truenas.lan --identity ~/.ssh/id_ed25519
EOF
}

HOST=""
SSH_USER="root"
SSH_PORT="22"
IDENTITY=""
OUTPUT_DIR=""
INCLUDE_BUILTIN=0
NO_REPORT=0
DRY_RUN=0

# parse_args: parses CLI flags into globals. Arguments: "$@"
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host) HOST="${2:?--host requires a value}"; shift 2 ;;
            --user) SSH_USER="${2:?--user requires a value}"; shift 2 ;;
            --port) SSH_PORT="${2:?--port requires a value}"; shift 2 ;;
            --identity) IDENTITY="${2:?--identity requires a value}"; shift 2 ;;
            --output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
            --include-builtin) INCLUDE_BUILTIN=1; shift ;;
            --no-report) NO_REPORT=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes) ASSUME_YES=1; shift ;;
            --no-color) NO_COLOR=1; init_colors; shift ;;
            -h|--help) usage; exit "$EXIT_OK" ;;
            -v|--version) print_version "$PROG_NAME" ;;
            *) log_error "Unknown argument: $1"; usage; exit "$EXIT_INVALID_ARGS" ;;
        esac
    done

    if [[ -z "$HOST" ]]; then
        log_error "--host is required"
        usage
        exit "$EXIT_INVALID_ARGS"
    fi
}

# fetch_system_info: fetches system.info from the target. Arguments: none.
# Echoes the JSON to stdout.
fetch_system_info() {
    transport_midclt "system.info"
}

# fetch_users: fetches user.query, filters builtin users unless
# --include-builtin was given. Arguments: none. Echoes JSON array to stdout.
fetch_users() {
    local raw
    raw="$(transport_midclt "user.query")"
    if [[ "$INCLUDE_BUILTIN" == "1" ]]; then
        echo "$raw" | jq '[.[] | {
            id, uid, username, full_name, email,
            group_gid: (.group.bsdgrp_gid // null),
            group_name: (.group.bsdgrp_group // null),
            groups, home, shell, locked, password_disabled, smb,
            sudo_commands, sudo_commands_nopasswd, sshpubkey, immutable,
            twofactor_auth_configured, attributes
        }]'
    else
        echo "$raw" | jq '[.[] | select(.builtin == false) | {
            id, uid, username, full_name, email,
            group_gid: (.group.bsdgrp_gid // null),
            group_name: (.group.bsdgrp_group // null),
            groups, home, shell, locked, password_disabled, smb,
            sudo_commands, sudo_commands_nopasswd, sshpubkey, immutable,
            twofactor_auth_configured, attributes
        }]'
    fi
}

# fetch_groups: fetches group.query, filters builtin groups unless
# --include-builtin was given. Arguments: none. Echoes JSON array to stdout.
fetch_groups() {
    local raw
    raw="$(transport_midclt "group.query")"
    if [[ "$INCLUDE_BUILTIN" == "1" ]]; then
        echo "$raw" | jq '[.[] | {id, gid, name, sudo_commands, sudo_commands_nopasswd, smb, users}]'
    else
        echo "$raw" | jq '[.[] | select(.builtin == false) | {id, gid, name, sudo_commands, sudo_commands_nopasswd, smb, users}]'
    fi
}

main() {
    parse_args "$@"

    require_cmd ssh
    require_cmd jq

    transport_configure "$HOST" "$SSH_USER" "$SSH_PORT" "$IDENTITY"
    transport_check

    log_info "Fetching system info from $(transport_target) ..."
    local sysinfo
    sysinfo="$(fetch_system_info)"
    local source_version
    source_version="$(echo "$sysinfo" | jq -r '.version // "unknown"')"
    local remote_hostname
    remote_hostname="$(echo "$sysinfo" | jq -r '.hostname // "unknown"')"

    log_info "Fetching users ..."
    local users_json
    users_json="$(fetch_users)"
    local user_count
    user_count="$(echo "$users_json" | jq 'length')"

    log_info "Fetching groups ..."
    local groups_json
    groups_json="$(fetch_groups)"
    local group_count
    group_count="$(echo "$groups_json" | jq 'length')"

    log_success "Fetched $user_count user(s) and $group_count group(s) from $remote_hostname ($source_version)."

    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "Dry run: no files written."
        exit "$EXIT_OK"
    fi

    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="./backups/${HOST}-$(utc_timestamp)"
    fi
    mkdir -p "$OUTPUT_DIR"

    local doc
    doc="$(schema_new_document "api" "$remote_hostname" "$source_version" "false")"
    doc="$(echo "$doc" | jq --argjson u "$users_json" --argjson g "$groups_json" '.users = $u | .groups = $g')"

    local out_file="$OUTPUT_DIR/backup.json"
    echo "$doc" | jq '.' > "$out_file"
    report_chmod "$out_file"
    log_success "Wrote backup JSON: $out_file"

    if [[ "$NO_REPORT" != "1" ]]; then
        report_generate_html "$out_file" "$OUTPUT_DIR/report.html"
        report_generate_markdown "$out_file" "$OUTPUT_DIR/report.md"
    fi

    echo ""
    echo "${COLOR_BOLD}Summary${COLOR_RESET}"
    echo "  Host:    $remote_hostname ($source_version)"
    echo "  Users:   $user_count"
    echo "  Groups:  $group_count"
    echo "  Output:  $OUTPUT_DIR"
    exit "$EXIT_OK"
}

main "$@"
