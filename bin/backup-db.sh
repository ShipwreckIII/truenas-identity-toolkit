#!/usr/bin/env bash
# backup-db.sh - Extract local users, groups, and password hashes from a
# TrueNAS SCALE configuration backup file (raw freenas-v1.db SQLite file, or
# the .tar bundle downloaded from the SCALE UI's "Save Config"), producing
# the same schema-v1 JSON that backup-api.sh produces, but with password
# hashes populated in a per-user "hashes" object.
#
# Column names inside account_bsdusers / account_bsdgroups have shifted
# across SCALE releases, so this script introspects the schema at runtime
# (PRAGMA table_info) rather than hardcoding column names. See
# docs/FIELD-REFERENCE.md and docs/ARCHITECTURE.md for details and caveats.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/schema.sh
source "$LIB_DIR/schema.sh"
# shellcheck source=lib/report.sh
source "$LIB_DIR/report.sh"

trap cleanup_tempdirs EXIT

readonly PROG_NAME="backup-db.sh"

# usage: prints help text. Arguments: none.
usage() {
    cat <<EOF
$PROG_NAME - Extract users/groups/hashes from a TrueNAS SCALE config backup.

Accepts either a raw freenas-v1.db SQLite file or the .tar bundle downloaded
from the SCALE UI (System Settings -> General -> Manage Configuration ->
Save Config). Output uses the same schema as backup-api.sh, but includes
password hashes (bsdusr_unixhash / bsdusr_smbhash) per user, which
'midclt call user.query' never exposes on a live system.

Usage:
  $PROG_NAME --input <path> [options]

Required:
  --input <path>                 Path to freenas-v1.db or a config .tar

Options:
  --output-dir <path>            Output directory
                                   (default: ./backups/from-db-<UTC-timestamp>/)
  --include-builtin              Include builtin users/groups (default: off)
  --no-report                    Skip HTML/Markdown report generation
  --yes                          Assume yes on all confirmation prompts
  --no-color                     Disable colored output
  -h, --help                     Show this help and exit
  -v, --version                  Show version and exit

Output security:
  The resulting backup.json contains password hashes and is written with
  permissions 0600. Reports never render hash values, only
  <hash-present> / <hash-absent>.

Exit codes:
  0 success   1 general error   2 invalid arguments   3 connectivity failure
  4 validation failure          5 partial success

Example:
  $PROG_NAME --input ./config-backup.tar --output-dir ./backups/migration1
EOF
}

INPUT_PATH=""
OUTPUT_DIR=""
INCLUDE_BUILTIN=0
NO_REPORT=0

# parse_args: parses CLI flags into globals. Arguments: "$@"
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --input) INPUT_PATH="${2:?--input requires a value}"; shift 2 ;;
            --output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
            --include-builtin) INCLUDE_BUILTIN=1; shift ;;
            --no-report) NO_REPORT=1; shift ;;
            --yes)
                # shellcheck disable=SC2034 # read by lib/common.sh, not here
                ASSUME_YES=1
                shift
                ;;
            --no-color)
                # shellcheck disable=SC2034 # read by lib/common.sh, not here
                NO_COLOR=1
                init_colors
                shift
                ;;
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

# resolve_db_file: given the --input path, returns a path to a raw SQLite
# database file, extracting a tarball to a temp dir (auto-cleaned) if
# necessary. Arguments: input_path. Echoes the resolved db path to stdout.
resolve_db_file() {
    local input_path="$1"
    local fmt
    fmt="$(detect_input_format "$input_path")"

    if [[ "$fmt" == "sqlite" ]]; then
        log_info "Detected raw SQLite database: $input_path"
        echo "$input_path"
        return 0
    fi

    log_info "Detected tar bundle, extracting: $input_path"
    local extract_dir
    extract_dir="$(mktempdir "tnit-configdb")"
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
    log_info "Found database inside bundle: $(basename "$found_db")"
    echo "$found_db"
}

# db_verify_integrity: runs PRAGMA integrity_check. Arguments: db_path.
# Returns: 0 if the check reports "ok"; dies otherwise.
db_verify_integrity() {
    local db_path="$1"
    local result
    result="$(sqlite3 "$db_path" "PRAGMA integrity_check;" 2>&1 | tr -d '\r')" || \
        die "sqlite3 could not open $db_path: $result" "$EXIT_VALIDATION_FAILURE"

    if [[ "$result" != "ok" ]]; then
        die "SQLite integrity check failed for $db_path: $result" "$EXIT_VALIDATION_FAILURE"
    fi
    log_success "SQLite integrity check passed."
}

# db_list_tables: lists table names in the database. Arguments: db_path.
# Echoes one table name per line.
db_list_tables() {
    local db_path="$1"
    sqlite3 -noheader -list "$db_path" "SELECT name FROM sqlite_master WHERE type='table';" | tr -d '\r'
}

# db_table_columns: lists column names for a table. Arguments: db_path, table.
# Echoes one column name per line.
db_table_columns() {
    local db_path="$1"
    local table="$2"
    sqlite3 -noheader -list "$db_path" "PRAGMA table_info(\"$table\");" | tr -d '\r' | awk -F'|' '{print $2}'
}

# has_column: checks whether a column name is present in a newline-separated
# list. Arguments: columns_string, column_name. Returns: 0 if present.
has_column() {
    local columns="$1"
    local column="$2"
    printf '%s\n' "$columns" | grep -qxF "$column"
}

# find_membership_table: looks for a users<->groups join table among the
# given table list. Arguments: tables_string. Echoes the table name if
# found, or empty string if not.
find_membership_table() {
    local tables="$1"
    local candidate
    # Note: grep legitimately finds nothing here when there is no
    # membership table; under `set -o pipefail` that makes the pipeline's
    # exit status non-zero, which would otherwise trip `set -e` on this
    # plain assignment. `|| true` makes "not found" a normal, non-fatal
    # empty result instead of killing the script.
    candidate="$(printf '%s\n' "$tables" | grep -ix 'account_bsdgroupmembership' | head -n1 || true)"
    if [[ -z "$candidate" ]]; then
        candidate="$(printf '%s\n' "$tables" | grep -iE 'bsd.*group.*member|bsdusers.*bsdgroups' | head -n1 || true)"
    fi
    echo "$candidate"
}

USERS_TABLE=""
GROUPS_TABLE=""
MEMBERSHIP_TABLE=""
declare -A USER_COLS_PRESENT=()
declare -A GROUP_COLS_PRESENT=()

# introspect_schema: locates the account_bsdusers / account_bsdgroups tables
# (and an optional membership join table), validating that critical columns
# exist. Dies if the file does not look like a TrueNAS SCALE config backup.
# Arguments: db_path
introspect_schema() {
    local db_path="$1"
    local tables
    tables="$(db_list_tables "$db_path")"

    if ! printf '%s\n' "$tables" | grep -qxi 'account_bsdusers'; then
        die "This does not appear to be a TrueNAS SCALE config backup (table 'account_bsdusers' not found)." "$EXIT_VALIDATION_FAILURE"
    fi
    if ! printf '%s\n' "$tables" | grep -qxi 'account_bsdgroups'; then
        die "This does not appear to be a TrueNAS SCALE config backup (table 'account_bsdgroups' not found)." "$EXIT_VALIDATION_FAILURE"
    fi
    USERS_TABLE="$(printf '%s\n' "$tables" | grep -ix 'account_bsdusers' | head -n1 || true)"
    GROUPS_TABLE="$(printf '%s\n' "$tables" | grep -ix 'account_bsdgroups' | head -n1 || true)"
    MEMBERSHIP_TABLE="$(find_membership_table "$tables")"

    if [[ -n "$MEMBERSHIP_TABLE" ]]; then
        log_info "Group membership join table: $MEMBERSHIP_TABLE"
    else
        log_warn "No group-membership join table found; auxiliary group memberships will be empty (primary group only)."
    fi

    local user_cols group_cols
    user_cols="$(db_table_columns "$db_path" "$USERS_TABLE")"
    group_cols="$(db_table_columns "$db_path" "$GROUPS_TABLE")"

    log_debug "Columns in $USERS_TABLE: $(printf '%s' "$user_cols" | tr '\n' ' ')"
    log_debug "Columns in $GROUPS_TABLE: $(printf '%s' "$group_cols" | tr '\n' ' ')"

    local uid_col username_col
    uid_col="$(pick_column "$user_cols" bsdusr_uid uid)"
    username_col="$(pick_column "$user_cols" bsdusr_username username)"
    if [[ -z "$uid_col" || -z "$username_col" ]]; then
        die "Critical columns missing from $USERS_TABLE: need a uid column and a username column." "$EXIT_VALIDATION_FAILURE"
    fi

    # Record which canonical fields are actually present for later logging
    # of what's missing (spec: warn, don't fail, on missing non-critical
    # columns).
    local canonical
    for canonical in uid username full_name email home shell locked \
        password_disabled smb sudo_commands sudo_commands_nopasswd \
        sshpubkey unixhash smbhash builtin group_id immutable; do
        USER_COLS_PRESENT["$canonical"]="$(pick_column "$user_cols" "bsdusr_${canonical}" "${canonical}")"
        if [[ -z "${USER_COLS_PRESENT[$canonical]}" ]]; then
            log_warn "Column for user field '$canonical' not found in $USERS_TABLE; will be null in output."
        fi
    done

    for canonical in gid sudo_commands sudo_commands_nopasswd smb builtin; do
        GROUP_COLS_PRESENT["$canonical"]="$(pick_column "$group_cols" "bsdgrp_${canonical}" "${canonical}")"
        if [[ -z "${GROUP_COLS_PRESENT[$canonical]}" ]]; then
            log_warn "Column for group field '$canonical' not found in $GROUPS_TABLE; will be null in output."
        fi
    done
    # Group "name" is conventionally stored as bsdgrp_group, not bsdgrp_name
    # - list that candidate first so the common case doesn't warn spuriously.
    GROUP_COLS_PRESENT[name]="$(pick_column "$group_cols" bsdgrp_group bsdgrp_name bsdgrp_groupname name)"
    if [[ -z "${GROUP_COLS_PRESENT[name]}" ]]; then
        log_warn "Column for group field 'name' not found in $GROUPS_TABLE; will be null in output."
    fi
}

# pick_column: returns the first candidate column name that exists in the
# given newline-separated column list. Arguments: columns_string,
# candidate... Echoes the match, or empty string if none matched.
pick_column() {
    local columns="$1"
    shift
    local candidate
    for candidate in "$@"; do
        if has_column "$columns" "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
}

# sql_select_expr: builds a "col AS alias" fragment, or "NULL AS alias" if
# the column was not found. Arguments: actual_column_or_empty, alias
sql_select_expr() {
    local actual="$1"
    local alias="$2"
    if [[ -n "$actual" ]]; then
        printf '"%s" AS %s' "$actual" "$alias"
    else
        printf 'NULL AS %s' "$alias"
    fi
}

# extract_users_json: runs the SELECT against account_bsdusers and returns
# the raw rows as a JSON array (sqlite3 -json). Arguments: db_path
extract_users_json() {
    local db_path="$1"
    local -a exprs=()
    exprs+=("$(sql_select_expr "id" "row_id")")
    local field
    for field in uid username full_name email home shell locked \
        password_disabled smb sudo_commands sudo_commands_nopasswd \
        sshpubkey unixhash smbhash builtin group_id immutable; do
        exprs+=("$(sql_select_expr "${USER_COLS_PRESENT[$field]}" "$field")")
    done
    local select_list
    select_list="$(IFS=,; echo "${exprs[*]}")"
    sqlite3 -json "$db_path" "SELECT $select_list FROM \"$USERS_TABLE\";"
}

# extract_groups_json: runs the SELECT against account_bsdgroups and returns
# the raw rows as a JSON array (sqlite3 -json). Arguments: db_path
extract_groups_json() {
    local db_path="$1"
    local -a exprs=()
    exprs+=("$(sql_select_expr "id" "row_id")")
    local field
    for field in gid name sudo_commands sudo_commands_nopasswd smb builtin; do
        exprs+=("$(sql_select_expr "${GROUP_COLS_PRESENT[$field]}" "$field")")
    done
    local select_list
    select_list="$(IFS=,; echo "${exprs[*]}")"
    sqlite3 -json "$db_path" "SELECT $select_list FROM \"$GROUPS_TABLE\";"
}

# extract_membership_json: runs a SELECT against the membership join table,
# if one was found. Arguments: db_path. Echoes a JSON array of
# {user_ref, group_ref} rows (raw FK values, column names vary), or "[]".
extract_membership_json() {
    local db_path="$1"
    if [[ -z "$MEMBERSHIP_TABLE" ]]; then
        echo "[]"
        return 0
    fi
    sqlite3 -json "$db_path" "SELECT * FROM \"$MEMBERSHIP_TABLE\";"
}

# normalize_users: converts raw extracted user rows + membership info into
# the toolkit's canonical user JSON shape. Arguments: users_raw_json,
# groups_raw_json, membership_raw_json. Echoes the normalized users array.
normalize_users() {
    local users_raw="$1"
    local groups_raw="$2"
    local membership_raw="$3"

    jq -c \
        --argjson groups "$groups_raw" \
        --argjson membership "$membership_raw" \
        '
        # SQLite has no native boolean type; bsdusr_locked/bsdusr_smb/etc.
        # come back as integers 0/1 (or, on some drivers, real booleans).
        # The jq alternative operator only falls back on false/null, so
        # "0 // false" would wrongly yield 0 - use explicit coercion instead.
        def as_bool: (. == 1) or (. == true);
        # Build a lookup of group row_id -> {gid, name}
        (reduce $groups[] as $g ({}; .[$g.row_id | tostring] = {gid: $g.gid, name: $g.name})) as $grp_by_id
        |
        # For each membership row, find the user-ref and group-ref keys
        # heuristically (any key containing "user" -> user side, any key
        # containing "group" -> group side), building user_row_id -> [gid,...]
        (reduce $membership[] as $m ({};
            ($m | keys | map(select(test("user"; "i")))[0]) as $ukey |
            ($m | keys | map(select(test("group"; "i")))[0]) as $gkey |
            if $ukey and $gkey and $m[$ukey] != null and $m[$gkey] != null then
                (.[$m[$ukey] | tostring] //= []) |
                .[$m[$ukey] | tostring] += [ ($grp_by_id[$m[$gkey] | tostring].gid // $m[$gkey]) ]
            else . end
        )) as $aux_by_user
        |
        [ .[] as $u | ($u // {}) | {
            id: .row_id,
            uid: .uid,
            username: .username,
            full_name: .full_name,
            email: .email,
            group_gid: ($grp_by_id[(.group_id | tostring)].gid // null),
            group_name: ($grp_by_id[(.group_id | tostring)].name // null),
            groups: ($aux_by_user[(.row_id | tostring)] // []),
            home: .home,
            shell: .shell,
            locked: (.locked | as_bool),
            password_disabled: (.password_disabled | as_bool),
            smb: (.smb | as_bool),
            sudo_commands: ((.sudo_commands // "[]") as $s | ($s | try fromjson catch [])),
            sudo_commands_nopasswd: ((.sudo_commands_nopasswd // "[]") as $s | ($s | try fromjson catch [])),
            sshpubkey: .sshpubkey,
            immutable: (.immutable | as_bool),
            twofactor_auth_configured: false,
            attributes: {},
            builtin: (
                if .builtin != null then (.builtin | as_bool)
                else ((.uid // 999999) | tonumber? // 999999) < 1000
                end
            ),
            hashes: { unixhash: .unixhash, smbhash: .smbhash }
        } ]
    ' <<< "$users_raw"
}

# normalize_groups: converts raw extracted group rows into the toolkit's
# canonical group JSON shape (adds a "builtin" field used only for
# filtering; stripped before output). Arguments: groups_raw_json,
# membership_raw_json. Echoes the normalized groups array.
normalize_groups() {
    local groups_raw="$1"
    local membership_raw="$2"

    jq -c \
        --argjson membership "$membership_raw" \
        '
        def as_bool: (. == 1) or (. == true);
        (reduce $membership[] as $m ({};
            ($m | keys | map(select(test("user"; "i")))[0]) as $ukey |
            ($m | keys | map(select(test("group"; "i")))[0]) as $gkey |
            if $ukey and $gkey and $m[$ukey] != null and $m[$gkey] != null then
                (.[$m[$gkey] | tostring] //= []) |
                .[$m[$gkey] | tostring] += [ $m[$ukey] ]
            else . end
        )) as $users_by_group
        |
        [ .[] | {
            id: .row_id,
            gid: .gid,
            name: .name,
            sudo_commands: ((.sudo_commands // "[]") as $s | ($s | try fromjson catch [])),
            sudo_commands_nopasswd: ((.sudo_commands_nopasswd // "[]") as $s | ($s | try fromjson catch [])),
            smb: (.smb | as_bool),
            users: ($users_by_group[(.row_id | tostring)] // []),
            builtin: (
                if .builtin != null then (.builtin | as_bool)
                else ((.gid // 999999) | tonumber? // 999999) < 1000
                end
            )
        } ]
    ' <<< "$groups_raw"
}

main() {
    parse_args "$@"

    require_cmd sqlite3
    require_cmd jq
    require_cmd tar

    local db_path
    db_path="$(resolve_db_file "$INPUT_PATH")"

    db_verify_integrity "$db_path"
    introspect_schema "$db_path"

    log_info "Extracting users from $USERS_TABLE ..."
    local users_raw groups_raw membership_raw
    users_raw="$(extract_users_json "$db_path")"
    log_info "Extracting groups from $GROUPS_TABLE ..."
    groups_raw="$(extract_groups_json "$db_path")"
    membership_raw="$(extract_membership_json "$db_path")"

    local users_norm groups_norm
    users_norm="$(normalize_users "$users_raw" "$groups_raw" "$membership_raw")"
    groups_norm="$(normalize_groups "$groups_raw" "$membership_raw")"

    if [[ "$INCLUDE_BUILTIN" != "1" ]]; then
        users_norm="$(echo "$users_norm" | jq '[.[] | select(.builtin == false)]')"
        groups_norm="$(echo "$groups_norm" | jq '[.[] | select(.builtin == false)]')"
    fi
    # Strip the internal "builtin" filter field before writing output; it is
    # not part of the public schema (backup-api.sh does not emit it either).
    users_norm="$(echo "$users_norm" | jq '[.[] | del(.builtin)]')"
    groups_norm="$(echo "$groups_norm" | jq '[.[] | del(.builtin)]')"

    local user_count group_count
    user_count="$(echo "$users_norm" | jq 'length')"
    group_count="$(echo "$groups_norm" | jq 'length')"

    local any_hashes
    any_hashes="$(echo "$users_norm" | jq '[.[] | select((.hashes.unixhash // "") != "" or (.hashes.smbhash // "") != "")] | length > 0')"

    log_success "Extracted $user_count user(s) and $group_count group(s) from $(basename "$db_path")."
    if [[ "$any_hashes" == "true" ]]; then
        log_warn "This backup contains password hashes. The output file will be chmod 600."
    else
        log_warn "No password hashes were found in the source columns (unixhash/smbhash both empty or columns missing)."
    fi

    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="./backups/from-db-$(utc_timestamp)"
    fi
    mkdir -p "$OUTPUT_DIR"

    local doc
    doc="$(schema_new_document "config-db" "$(basename "$INPUT_PATH")" "unknown" "$any_hashes")"
    doc="$(echo "$doc" | jq --argjson u "$users_norm" --argjson g "$groups_norm" '.users = $u | .groups = $g')"
    if [[ "$any_hashes" == "true" ]]; then
        doc="$(echo "$doc" | jq '.hash_warning = "This file contains password hashes (unixhash/smbhash). Restrict access; permissions are set to 0600."')"
    fi

    local out_file="$OUTPUT_DIR/backup.json"
    echo "$doc" | jq '.' > "$out_file"

    if [[ "$any_hashes" == "true" ]]; then
        secure_chmod "$out_file"
    else
        report_chmod "$out_file"
    fi
    log_success "Wrote backup JSON: $out_file"

    if [[ "$NO_REPORT" != "1" ]]; then
        report_generate_html "$out_file" "$OUTPUT_DIR/report.html"
        report_generate_markdown "$out_file" "$OUTPUT_DIR/report.md"
    fi

    echo ""
    echo "${COLOR_BOLD}Summary${COLOR_RESET}"
    echo "  Source:  $INPUT_PATH"
    echo "  Users:   $user_count"
    echo "  Groups:  $group_count"
    echo "  Hashes:  $any_hashes"
    echo "  Output:  $OUTPUT_DIR"
    exit "$EXIT_OK"
}

main "$@"
