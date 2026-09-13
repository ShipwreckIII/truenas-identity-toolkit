#!/usr/bin/env bash
# inspect-config-db.sh - Standalone diagnostic tool for a TrueNAS SCALE
# configuration backup file (raw freenas-v1.db or the .tar bundle from the
# SCALE UI). Prints structural information useful for troubleshooting and
# for sanity-checking a file before feeding it to backup-db.sh. Never
# prints a hash value - only presence/absence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

trap cleanup_tempdirs EXIT

readonly PROG_NAME="inspect-config-db.sh"

# usage: prints help text. Arguments: none.
usage() {
    cat <<EOF
$PROG_NAME - Inspect a TrueNAS SCALE config backup without extracting it.

Prints detected format, SQLite integrity, table/column layout, and
non-builtin user/group counts. Never prints a password hash value - only
whether one is present or absent per user.

Usage:
  $PROG_NAME --input <path>

Required:
  --input <path>          Path to freenas-v1.db or a config .tar

Options:
  --no-color               Disable colored output
  -h, --help                Show this help and exit
  -v, --version              Show version and exit

Exit codes:
  0 success   1 general error   2 invalid arguments   4 validation failure

Example:
  $PROG_NAME --input ./config-backup.tar
EOF
}

INPUT_PATH=""

# parse_args: parses CLI flags into globals. Arguments: "$@"
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --input) INPUT_PATH="${2:?--input requires a value}"; shift 2 ;;
            --no-color) NO_COLOR=1; init_colors; shift ;;
            -h|--help) usage; exit "$EXIT_OK" ;;
            -v|--version) print_version "$PROG_NAME" ;;
            *) log_error "Unknown argument: $1"; usage; exit "$EXIT_INVALID_ARGS" ;;
        esac
    done

    if [[ -z "$INPUT_PATH" ]]; then
        log_error "--input is required"
        usage
        exit "$EXIT_INVALID_ARGS"
    fi
    if [[ ! -f "$INPUT_PATH" ]]; then
        die "Input file not found: $INPUT_PATH" "$EXIT_INVALID_ARGS"
    fi
}

# detect_input_format: inspects magic bytes to classify the input file.
# Arguments: file_path. Echoes "sqlite" or "tar" to stdout.
detect_input_format() {
    local file_path="$1"
    local magic
    magic="$(head -c 16 "$file_path" 2>/dev/null | tr -d '\0')"
    if [[ "$magic" == "SQLite format 3" ]]; then
        echo "sqlite"
    else
        echo "tar"
    fi
}

# resolve_db_file: extracts a tarball to a temp dir if needed and returns a
# raw SQLite file path. Arguments: input_path. Echoes the resolved path.
resolve_db_file() {
    local input_path="$1"
    local fmt
    fmt="$(detect_input_format "$input_path")"
    echo "Detected format: $fmt" >&2

    if [[ "$fmt" == "sqlite" ]]; then
        echo "$input_path"
        return 0
    fi

    local extract_dir
    extract_dir="$(mktempdir "tnit-inspect")"
    if ! tar -xf "$input_path" -C "$extract_dir" 2>/tmp/tnit_tar_err.$$; then
        local err
        err="$(cat /tmp/tnit_tar_err.$$ 2>/dev/null || true)"
        rm -f /tmp/tnit_tar_err.$$
        die "Failed to extract tar bundle: $err" "$EXIT_INVALID_ARGS"
    fi
    rm -f /tmp/tnit_tar_err.$$

    local found_db
    found_db="$(find "$extract_dir" -type f \( -name '*.db' -o -name 'freenas-v1.db' \) 2>/dev/null | head -n 1)"
    if [[ -z "$found_db" ]]; then
        die "No .db file found inside tar bundle: $input_path" "$EXIT_INVALID_ARGS"
    fi
    echo "$found_db"
}

# db_list_tables: lists table names. Arguments: db_path.
db_list_tables() {
    sqlite3 -noheader -list "$1" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" | tr -d '\r'
}

# db_table_columns: lists "name:type" per column. Arguments: db_path, table.
db_table_columns() {
    sqlite3 -noheader -list "$1" "PRAGMA table_info(\"$2\");" | tr -d '\r' | awk -F'|' '{print $2":"$3}'
}

# db_row_count: counts rows in a table. Arguments: db_path, table.
db_row_count() {
    sqlite3 -noheader -list "$1" "SELECT COUNT(*) FROM \"$2\";" | tr -d '\r'
}

main() {
    parse_args "$@"
    require_cmd sqlite3

    echo "${COLOR_BOLD}truenas-identity-toolkit: config backup inspector${COLOR_RESET}"
    echo "Input: $INPUT_PATH"
    echo ""

    local db_path
    db_path="$(resolve_db_file "$INPUT_PATH")"
    echo "Resolved database file: $db_path"

    local sqlite_version
    sqlite_version="$(sqlite3 -noheader -list "$db_path" "SELECT sqlite_version();" 2>&1 | tr -d '\r')" || \
        die "sqlite3 could not open $db_path: $sqlite_version" "$EXIT_VALIDATION_FAILURE"
    echo "SQLite library version: $sqlite_version"

    local schema_version
    schema_version="$(sqlite3 -noheader -list "$db_path" "PRAGMA user_version;" 2>/dev/null | tr -d '\r'; true)"
    [[ -z "$schema_version" ]] && schema_version="unknown"
    echo "Database user_version pragma: $schema_version"

    local integrity
    integrity="$(sqlite3 -noheader -list "$db_path" "PRAGMA integrity_check;" 2>&1 | tr -d '\r')"
    if [[ "$integrity" == "ok" ]]; then
        log_success "Integrity check: ok"
    else
        log_warn "Integrity check reported: $integrity"
    fi

    echo ""
    echo "${COLOR_BOLD}Tables${COLOR_RESET}"
    local tables
    tables="$(db_list_tables "$db_path")"
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        local count
        count="$(db_row_count "$db_path" "$t" 2>/dev/null || echo "?")"
        printf '  %-45s %s row(s)\n' "$t" "$count"
    done <<< "$tables"

    # Note: grep legitimately finds nothing when a table is absent (that is
    # exactly the case we are checking for below). Under `set -o pipefail`
    # that makes the pipeline exit non-zero, which would otherwise trip
    # `set -e` right here on a plain assignment, before the intended
    # "not found" handling ever runs. `|| true` makes that a normal,
    # non-fatal empty result.
    local users_table groups_table
    users_table="$(printf '%s\n' "$tables" | grep -ix 'account_bsdusers' | head -n1 || true)"
    groups_table="$(printf '%s\n' "$tables" | grep -ix 'account_bsdgroups' | head -n1 || true)"
    local membership_table
    membership_table="$(printf '%s\n' "$tables" | grep -ix 'account_bsdgroupmembership' | head -n1 || true)"
    if [[ -z "$membership_table" ]]; then
        membership_table="$(printf '%s\n' "$tables" | grep -iE 'bsd.*group.*member|bsdusers.*bsdgroups' | head -n1 || true)"
    fi

    if [[ -z "$users_table" || -z "$groups_table" ]]; then
        echo ""
        log_error "This does not appear to be a TrueNAS SCALE config backup:"
        # `[[ cond ]] && cmd` as a bare statement would itself trip `set -e`
        # when cond is false (e.g. only one table is missing), short-
        # circuiting past the `exit` below. Use full if-statements instead.
        if [[ -z "$users_table" ]]; then
            log_error "  - table 'account_bsdusers' not found"
        fi
        if [[ -z "$groups_table" ]]; then
            log_error "  - table 'account_bsdgroups' not found"
        fi
        exit "$EXIT_VALIDATION_FAILURE"
    fi

    echo ""
    echo "${COLOR_BOLD}Columns: $users_table${COLOR_RESET}"
    db_table_columns "$db_path" "$users_table" | sed 's/^/  /'

    echo ""
    echo "${COLOR_BOLD}Columns: $groups_table${COLOR_RESET}"
    db_table_columns "$db_path" "$groups_table" | sed 's/^/  /'

    if [[ -n "$membership_table" ]]; then
        echo ""
        echo "${COLOR_BOLD}Columns: $membership_table (membership join table)${COLOR_RESET}"
        db_table_columns "$db_path" "$membership_table" | sed 's/^/  /'
    else
        echo ""
        log_warn "No group-membership join table detected; auxiliary group memberships cannot be resolved."
    fi

    # Detect a builtin column, falling back to the uid/gid<1000 heuristic,
    # purely for reporting counts here - never mutates any file.
    local user_cols builtin_user_col uid_col
    user_cols="$(db_table_columns "$db_path" "$users_table" | cut -d: -f1)"
    builtin_user_col="$(printf '%s\n' "$user_cols" | grep -ix 'bsdusr_builtin' || true)"
    uid_col="$(printf '%s\n' "$user_cols" | grep -ix 'bsdusr_uid' || true)"

    local total_users non_builtin_users
    total_users="$(db_row_count "$db_path" "$users_table")"
    if [[ -n "$builtin_user_col" ]]; then
        non_builtin_users="$(sqlite3 -noheader -list "$db_path" "SELECT COUNT(*) FROM \"$users_table\" WHERE \"$builtin_user_col\" = 0;")"
    elif [[ -n "$uid_col" ]]; then
        non_builtin_users="$(sqlite3 -noheader -list "$db_path" "SELECT COUNT(*) FROM \"$users_table\" WHERE \"$uid_col\" >= 1000;")"
    else
        non_builtin_users="unknown"
    fi

    local group_cols builtin_group_col gid_col
    group_cols="$(db_table_columns "$db_path" "$groups_table" | cut -d: -f1)"
    builtin_group_col="$(printf '%s\n' "$group_cols" | grep -ix 'bsdgrp_builtin' || true)"
    gid_col="$(printf '%s\n' "$group_cols" | grep -ix 'bsdgrp_gid' || true)"

    local total_groups non_builtin_groups
    total_groups="$(db_row_count "$db_path" "$groups_table")"
    if [[ -n "$builtin_group_col" ]]; then
        non_builtin_groups="$(sqlite3 -noheader -list "$db_path" "SELECT COUNT(*) FROM \"$groups_table\" WHERE \"$builtin_group_col\" = 0;")"
    elif [[ -n "$gid_col" ]]; then
        non_builtin_groups="$(sqlite3 -noheader -list "$db_path" "SELECT COUNT(*) FROM \"$groups_table\" WHERE \"$gid_col\" >= 1000;")"
    else
        non_builtin_groups="unknown"
    fi

    echo ""
    echo "${COLOR_BOLD}Account summary${COLOR_RESET}"
    echo "  Users:  $total_users total, $non_builtin_users non-builtin"
    echo "  Groups: $total_groups total, $non_builtin_groups non-builtin"

    local unixhash_col smbhash_col
    unixhash_col="$(printf '%s\n' "$user_cols" | grep -ix 'bsdusr_unixhash' || true)"
    smbhash_col="$(printf '%s\n' "$user_cols" | grep -ix 'bsdusr_smbhash' || true)"

    echo ""
    echo "${COLOR_BOLD}Password hash columns${COLOR_RESET}"
    if [[ -n "$unixhash_col" ]]; then
        local present
        present="$(sqlite3 -noheader -list "$db_path" "SELECT COUNT(*) FROM \"$users_table\" WHERE \"$unixhash_col\" IS NOT NULL AND \"$unixhash_col\" != '';")"
        echo "  unixhash column ($unixhash_col): present for $present/$total_users user(s) [values never shown]"
    else
        echo "  unixhash column: not found"
    fi
    if [[ -n "$smbhash_col" ]]; then
        local present
        present="$(sqlite3 -noheader -list "$db_path" "SELECT COUNT(*) FROM \"$users_table\" WHERE \"$smbhash_col\" IS NOT NULL AND \"$smbhash_col\" != '';")"
        echo "  smbhash column ($smbhash_col): present for $present/$total_users user(s) [values never shown]"
    else
        echo "  smbhash column: not found"
    fi

    exit "$EXIT_OK"
}

main "$@"
