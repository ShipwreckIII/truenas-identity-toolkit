#!/usr/bin/env bash
# restore.sh - Restore local users/groups from a schema-v1 backup JSON
# (produced by backup-api.sh or backup-db.sh) onto a target TrueNAS SCALE
# system over SSH+midclt. Groups are restored before users; both are
# matched to existing target entities by NAME, never by uid/gid (see
# docs/ARCHITECTURE.md for why). Conflicts are resolved interactively via
# lib/conflict.sh, with an "apply to all" memory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/transport.sh
source "$LIB_DIR/transport.sh"
# shellcheck source=lib/schema.sh
source "$LIB_DIR/schema.sh"
# shellcheck source=lib/conflict.sh
source "$LIB_DIR/conflict.sh"
# shellcheck source=lib/policy.sh
source "$LIB_DIR/policy.sh"

trap cleanup_tempdirs EXIT

readonly PROG_NAME="restore.sh"

# usage: prints help text. Arguments: none.
usage() {
    cat <<EOF
$PROG_NAME - Restore users/groups from a backup JSON onto a target SCALE
system over SSH+midclt.

Usage:
  $PROG_NAME --input <backup.json> --target-host <host> [options]

Required:
  --input <path>                 Backup JSON (from backup-api.sh or
                                   backup-db.sh)
  --target-host <hostname-or-ip> Target TrueNAS SCALE host

Options:
  --target-user <ssh-user>        SSH user (default: root)
  --target-port <ssh-port>        SSH port (default: 22)
  --target-identity <key-path>    SSH private key to use
  --config <path>                 restore.conf with policy defaults
                                    (see examples/restore.conf.example)
  --home-strategy <strategy>      skip|remap|preserve|prompt
                                    (default: skip)
  --home-remap <FROM>=<TO>        Prefix remap rule (repeatable; used when
                                    --home-strategy=remap)
  --shell-fallback <path>         Shell to use when the backup's shell is
                                    missing on target (default: /usr/bin/bash)
  --output-dir <path>             Where to write restore.log
                                    (default: ./restore-logs/<host>-<UTC-ts>/)
  --dry-run                       Show planned operations; make no changes
  --yes-to-all-conflicts <mode>   skip|overwrite - resolve every conflict
                                    the same way without prompting
  --yes                           Assume yes on confirmation prompts
                                    (conflicts still follow the rule above,
                                    or default to skip if unset)
  --no-color                      Disable colored output
  -h, --help                      Show this help and exit
  -v, --version                   Show version and exit

Password handling:
  - Backups from backup-db.sh (source=config-db) carry password hashes,
    but current TrueNAS SCALE has no documented, supported way to set a
    user's password from a raw hash via midclt (see docs/ARCHITECTURE.md).
    Every user therefore goes through the same interactive prompt below.
  - For each user needing a password decision:
      [t]emp-password / [d]isable-password / [l]ock-account / [s]kip-user

Exit codes:
  0 success   1 general error   2 invalid arguments   3 connectivity failure
  4 validation failure          5 partial success (some items failed)

Example:
  $PROG_NAME --input ./backups/migration1/backup.json \\
      --target-host truenas2.lan --home-strategy remap \\
      --home-remap /mnt/tank/home=/mnt/newpool/home
EOF
}

INPUT_PATH=""
TARGET_HOST=""
TARGET_USER="root"
TARGET_PORT="22"
TARGET_IDENTITY=""
CONFIG_PATH=""
HOME_STRATEGY="skip"
SHELL_FALLBACK="/usr/bin/bash"
OUTPUT_DIR=""
DRY_RUN=0
declare -a HOME_REMAP_RULES=()
YES_TO_ALL_CONFLICTS=""

# load_config: applies defaults from a restore.conf file. Only recognized
# KEY=VALUE lines are honored (comments '#' and blank lines are skipped);
# this is a restricted parser, not a bash `source`, so a config file can
# never execute arbitrary code. Arguments: config_path
load_config() {
    local config_path="$1"
    if [[ ! -f "$config_path" ]]; then
        die "Config file not found: $config_path" "$EXIT_INVALID_ARGS"
    fi

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        if [[ "$line" != *=* ]]; then
            log_warn "Ignoring malformed line in $config_path: $line"
            continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            HOME_STRATEGY) HOME_STRATEGY="$value" ;;
            HOME_REMAP) HOME_REMAP_RULES+=("$value") ;;
            SHELL_FALLBACK) SHELL_FALLBACK="$value" ;;
            YES_TO_ALL_CONFLICTS) YES_TO_ALL_CONFLICTS="$value" ;;
            TARGET_USER) TARGET_USER="$value" ;;
            TARGET_PORT) TARGET_PORT="$value" ;;
            *) log_warn "Unknown config key in $config_path: $key" ;;
        esac
    done < "$config_path"
}

# parse_args: parses CLI flags into globals. Config file (if any) is loaded
# first so explicit CLI flags always take precedence over it, regardless
# of argument order. Arguments: "$@"
parse_args() {
    local i args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
        if [[ "${args[$i]}" == "--config" ]]; then
            CONFIG_PATH="${args[$((i + 1))]:?--config requires a value}"
            load_config "$CONFIG_PATH"
            break
        fi
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --input) INPUT_PATH="${2:?--input requires a value}"; shift 2 ;;
            --target-host) TARGET_HOST="${2:?--target-host requires a value}"; shift 2 ;;
            --target-user) TARGET_USER="${2:?--target-user requires a value}"; shift 2 ;;
            --target-port) TARGET_PORT="${2:?--target-port requires a value}"; shift 2 ;;
            --target-identity) TARGET_IDENTITY="${2:?--target-identity requires a value}"; shift 2 ;;
            --config) shift 2 ;; # already handled above
            --home-strategy) HOME_STRATEGY="${2:?--home-strategy requires a value}"; shift 2 ;;
            --home-remap) HOME_REMAP_RULES+=("${2:?--home-remap requires a value}"); shift 2 ;;
            --shell-fallback) SHELL_FALLBACK="${2:?--shell-fallback requires a value}"; shift 2 ;;
            --output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes-to-all-conflicts) YES_TO_ALL_CONFLICTS="${2:?--yes-to-all-conflicts requires a value}"; shift 2 ;;
            --yes) ASSUME_YES=1; shift ;;
            --no-color) NO_COLOR=1; init_colors; shift ;;
            -h|--help) usage; exit "$EXIT_OK" ;;
            -v|--version) print_version "$PROG_NAME" ;;
            *) log_error "Unknown argument: $1"; usage; exit "$EXIT_INVALID_ARGS" ;;
        esac
    done

    if [[ -z "$INPUT_PATH" ]]; then
        log_error "--input is required"; usage; exit "$EXIT_INVALID_ARGS"
    fi
    if [[ -z "$TARGET_HOST" ]]; then
        log_error "--target-host is required"; usage; exit "$EXIT_INVALID_ARGS"
    fi
    case "$HOME_STRATEGY" in
        skip|remap|preserve|prompt) ;;
        *) die "Invalid --home-strategy: $HOME_STRATEGY (expected skip|remap|preserve|prompt)" "$EXIT_INVALID_ARGS" ;;
    esac
    if [[ -n "$YES_TO_ALL_CONFLICTS" ]]; then
        case "$YES_TO_ALL_CONFLICTS" in
            skip|overwrite) conflict_set_apply_all "$YES_TO_ALL_CONFLICTS" ;;
            *) die "Invalid --yes-to-all-conflicts: $YES_TO_ALL_CONFLICTS (expected skip|overwrite)" "$EXIT_INVALID_ARGS" ;;
        esac
    fi

    local rule
    for rule in "${HOME_REMAP_RULES[@]:-}"; do
        [[ -n "$rule" ]] && policy_add_home_remap "$rule"
    done
}

BACKUP_JSON=""
BACKUP_SOURCE=""
BACKUP_CONTAINS_HASHES="false"

# load_backup: validates and loads the backup JSON file. Arguments: path
load_backup() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        die "Backup file not found: $path" "$EXIT_INVALID_ARGS"
    fi
    schema_validate "$path" || exit "$EXIT_VALIDATION_FAILURE"
    BACKUP_JSON="$(cat "$path")"
    BACKUP_SOURCE="$(schema_source "$path")"
    BACKUP_CONTAINS_HASHES="$(schema_contains_hashes "$path")"
    log_success "Loaded backup: $(echo "$BACKUP_JSON" | jq '.users | length') user(s), $(echo "$BACKUP_JSON" | jq '.groups | length') group(s) [source=$BACKUP_SOURCE]"
}

TARGET_USERS_JSON="[]"
TARGET_GROUPS_JSON="[]"

# fetch_target_state: queries the target's current users/groups over
# midclt. Arguments: none.
fetch_target_state() {
    log_info "Fetching current users/groups from target ..."
    TARGET_USERS_JSON="$(transport_midclt "user.query")"
    TARGET_GROUPS_JSON="$(transport_midclt "group.query")"
}

# target_group_by_name: looks up a group on the target by name. Arguments:
# name. Echoes the JSON object, or "null" if not found.
target_group_by_name() {
    local name="$1"
    echo "$TARGET_GROUPS_JSON" | jq -c --arg n "$name" '[.[] | select(.group == $n or .name == $n)] | first // null'
}

# target_user_by_name: looks up a user on the target by username.
# Arguments: username. Echoes the JSON object, or "null" if not found.
target_user_by_name() {
    local username="$1"
    echo "$TARGET_USERS_JSON" | jq -c --arg n "$username" '[.[] | select(.username == $n)] | first // null'
}

RESTORE_LOG_FILE=""

# log_action: logs a restore action both to the console and to
# restore.log. Arguments: message
log_action() {
    local msg="$1"
    log_info "$msg"
    if [[ -n "$RESTORE_LOG_FILE" ]]; then
        printf '[%s] %s\n' "$(iso_timestamp)" "$msg" >> "$RESTORE_LOG_FILE"
    fi
}

CREATED_COUNT=0
UPDATED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
declare -a FAILED_REASONS=()

# remote_path_exists: checks whether a path exists on the target.
# Arguments: path, [test_flag] (default -e). Echoes "true"/"false".
remote_path_exists() {
    local path="$1"
    local flag="${2:--e}"
    [[ -z "$path" ]] && { echo "false"; return 0; }
    # Single-quote the path for the remote shell (escaping embedded single
    # quotes) rather than double-quoting it, so the path can never be
    # reinterpreted as shell metacharacters (`$`, backticks, etc.) on the
    # target - it comes from backup JSON data, not a trusted literal.
    local escaped_path="${path//\'/\'\\\'\'}"
    if transport_exec "test $flag '${escaped_path}'" 2>/dev/null; then
        echo "true"
    else
        echo "false"
    fi
}

# preflight_report: prints the planned operations for every backup group
# and user. Does not modify anything. Arguments: none.
preflight_report() {
    echo ""
    echo "${COLOR_BOLD}Pre-flight validation${COLOR_RESET}"
    echo ""
    echo "Groups:"
    local name gid target
    while IFS=$'\t' read -r name gid; do
        [[ -z "$name" ]] && continue
        target="$(target_group_by_name "$name")"
        if [[ "$target" == "null" ]]; then
            echo "  [create]  $name (gid=$gid)"
        else
            local target_gid
            target_gid="$(echo "$target" | jq -r '.gid')"
            if [[ "$target_gid" == "$gid" ]]; then
                echo "  [match]   $name (gid=$gid) - already present, identical gid"
            else
                echo "  [conflict] $name - backup gid=$gid, target gid=$target_gid"
            fi
        fi
    done < <(echo "$BACKUP_JSON" | jq -r '.groups[] | [.name, (.gid|tostring)] | @tsv' | tr -d '\r')

    echo ""
    echo "Users:"
    local username uid home shell
    while IFS=$'\t' read -r username uid home shell; do
        [[ -z "$username" ]] && continue
        target="$(target_user_by_name "$username")"
        if [[ "$target" == "null" ]]; then
            echo "  [create]  $username (uid=$uid)"
        else
            local target_uid
            target_uid="$(echo "$target" | jq -r '.uid')"
            if [[ "$target_uid" == "$uid" ]]; then
                echo "  [match]   $username (uid=$uid) - already present, identical uid"
            else
                echo "  [conflict] $username - backup uid=$uid, target uid=$target_uid"
            fi
        fi

        if [[ "$HOME_STRATEGY" != "skip" && -n "$home" ]]; then
            local parent exists
            parent="$(dirname "$home")"
            exists="$(remote_path_exists "$parent" -d)"
            [[ "$exists" != "true" ]] && echo "    warn: home parent '$parent' does not exist on target"
        fi
        if [[ -n "$shell" ]]; then
            local shell_exists
            shell_exists="$(remote_path_exists "$shell" -x)"
            [[ "$shell_exists" != "true" ]] && echo "    warn: shell '$shell' not found on target; will fall back to $SHELL_FALLBACK"
        fi
    done < <(echo "$BACKUP_JSON" | jq -r '.users[] | [.username, (.uid|tostring), (.home // ""), (.shell // "")] | @tsv' | tr -d '\r')
    echo ""
}

# restore_groups: creates/updates/skips every group in the backup, per
# conflict resolution. Arguments: none.
restore_groups() {
    local count
    count="$(echo "$BACKUP_JSON" | jq '.groups | length')"
    local idx
    for ((idx = 0; idx < count; idx++)); do
        local group name gid smb sudo_cmds sudo_cmds_np
        group="$(echo "$BACKUP_JSON" | jq -c ".groups[$idx]")"
        name="$(echo "$group" | jq -r '.name')"
        gid="$(echo "$group" | jq -r '.gid')"
        smb="$(echo "$group" | jq -r '.smb')"
        sudo_cmds="$(echo "$group" | jq -c '.sudo_commands // []')"
        sudo_cmds_np="$(echo "$group" | jq -c '.sudo_commands_nopasswd // []')"

        local target
        target="$(target_group_by_name "$name")"

        if [[ "$target" == "null" ]]; then
            if [[ "$DRY_RUN" == "1" ]]; then
                log_action "[dry-run] would create group '$name' (gid=$gid)"
                continue
            fi
            local payload result
            payload="$(jq -n --arg name "$name" --argjson gid "$gid" --argjson smb "$smb" \
                --argjson sc "$sudo_cmds" --argjson scnp "$sudo_cmds_np" \
                '{name: $name, gid: $gid, smb: $smb, sudo_commands: $sc, sudo_commands_nopasswd: $scnp}')"
            if result="$(transport_midclt_soft "group.create" "$payload")"; then
                log_action "Created group '$name' (gid=$gid)"
                CREATED_COUNT=$((CREATED_COUNT + 1))
            else
                log_action "FAILED to create group '$name': $result"
                FAILED_COUNT=$((FAILED_COUNT + 1))
                FAILED_REASONS+=("group '$name': $result")
            fi
            continue
        fi

        local target_gid
        target_gid="$(echo "$target" | jq -r '.gid')"
        if [[ "$target_gid" == "$gid" ]]; then
            log_action "Group '$name' already present and matches (gid=$gid); skipping"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            continue
        fi

        conflict_resolve "group" "$name" "gid=$gid" "gid=$target_gid"
        case "$CONFLICT_RESULT_ACTION" in
            skip)
                log_action "Skipped existing group '$name' per conflict resolution"
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                ;;
            overwrite)
                if [[ "$DRY_RUN" == "1" ]]; then
                    log_action "[dry-run] would update group '$name' to gid=$gid"
                    continue
                fi
                local target_id result
                target_id="$(echo "$target" | jq -r '.id')"
                if result="$(transport_midclt_soft "group.update" "[$target_id, {\"gid\": $gid}]")"; then
                    log_action "Updated group '$name' (gid $target_gid -> $gid)"
                    UPDATED_COUNT=$((UPDATED_COUNT + 1))
                else
                    log_action "FAILED to update group '$name': $result"
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                    FAILED_REASONS+=("group '$name': $result")
                fi
                ;;
            rename)
                local new_name="${name}_restored"
                if [[ "$DRY_RUN" == "1" ]]; then
                    log_action "[dry-run] would create renamed group '$new_name' (gid=$gid)"
                    continue
                fi
                local payload result
                payload="$(jq -n --arg name "$new_name" --argjson gid "$gid" --argjson smb "$smb" \
                    --argjson sc "$sudo_cmds" --argjson scnp "$sudo_cmds_np" \
                    '{name: $name, gid: $gid, smb: $smb, sudo_commands: $sc, sudo_commands_nopasswd: $scnp}')"
                if result="$(transport_midclt_soft "group.create" "$payload")"; then
                    log_action "Created renamed group '$new_name' (gid=$gid)"
                    CREATED_COUNT=$((CREATED_COUNT + 1))
                else
                    log_action "FAILED to create renamed group '$new_name': $result"
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                    FAILED_REASONS+=("group '$new_name': $result")
                fi
                ;;
        esac
    done
}

# resolve_password_action: interactively decides how to set a new user's
# password. Arguments: username. Sets PASSWORD_FIELDS_JSON to a JSON
# object fragment to merge into the create payload (e.g.
# {"password": "...", "locked": false} or {"password_disabled": true}).
PASSWORD_FIELDS_JSON='{"password_disabled": true}'
resolve_password_action() {
    local username="$1"

    if [[ "$ASSUME_YES" == "1" ]] || [[ ! -t 0 ]]; then
        log_warn "Non-interactive: disabling password for new user '$username'. Use an interactive session to set a temp password."
        PASSWORD_FIELDS_JSON='{"password_disabled": true}'
        return 0
    fi

    local reply
    while true; do
        read -r -p "Password for new user '$username'? [t]emp-password / [d]isable-password / [l]ock-account / [s]kip-user " reply
        case "$reply" in
            t|T|temp*)
                local pass
                read -r -s -p "Enter a temporary password for '$username': " pass
                echo "" >&2
                PASSWORD_FIELDS_JSON="$(jq -n --arg p "$pass" '{password: $p, password_disabled: false, locked: false}')"
                return 0
                ;;
            d|D|disable*)
                PASSWORD_FIELDS_JSON='{"password_disabled": true}'
                return 0
                ;;
            l|L|lock*)
                PASSWORD_FIELDS_JSON='{"password_disabled": true, "locked": true}'
                return 0
                ;;
            s|S|skip*)
                PASSWORD_FIELDS_JSON=""
                return 0
                ;;
            *) echo "Please answer t, d, l, or s." >&2 ;;
        esac
    done
}

# restore_users: creates/updates/skips every user in the backup. Must run
# after restore_groups (and after re-fetching target groups) so primary/
# auxiliary group names can be resolved to target group ids. Arguments:
# none.
restore_users() {
    log_info "Refreshing target group list for id resolution ..."
    TARGET_GROUPS_JSON="$(transport_midclt "group.query")"

    # Map of backup group gid -> name, used to translate a user's aux
    # `groups` (backup gids) into names, then into target ids.
    local backup_gid_to_name
    backup_gid_to_name="$(echo "$BACKUP_JSON" | jq -c '[.groups[] | {(.gid|tostring): .name}] | add // {}')"

    local count idx
    count="$(echo "$BACKUP_JSON" | jq '.users | length')"
    for ((idx = 0; idx < count; idx++)); do
        local user username uid home shell locked password_disabled smb
        local sudo_cmds sudo_cmds_np sshpubkey group_name aux_gids full_name email
        user="$(echo "$BACKUP_JSON" | jq -c ".users[$idx]")"
        username="$(echo "$user" | jq -r '.username')"
        uid="$(echo "$user" | jq -r '.uid')"
        full_name="$(echo "$user" | jq -r '.full_name // ""')"
        email="$(echo "$user" | jq -r '.email // empty')"
        home="$(echo "$user" | jq -r '.home // ""')"
        shell="$(echo "$user" | jq -r '.shell // ""')"
        locked="$(echo "$user" | jq -r '.locked // false')"
        smb="$(echo "$user" | jq -r '.smb // false')"
        sudo_cmds="$(echo "$user" | jq -c '.sudo_commands // []')"
        sudo_cmds_np="$(echo "$user" | jq -c '.sudo_commands_nopasswd // []')"
        sshpubkey="$(echo "$user" | jq -r '.sshpubkey // empty')"
        group_name="$(echo "$user" | jq -r '.group_name // empty')"
        aux_gids="$(echo "$user" | jq -c '.groups // []')"

        local target
        target="$(target_user_by_name "$username")"

        local action="create"
        if [[ "$target" != "null" ]]; then
            local target_uid
            target_uid="$(echo "$target" | jq -r '.uid')"
            if [[ "$target_uid" == "$uid" ]]; then
                log_action "User '$username' already present and matches (uid=$uid); skipping"
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                continue
            fi
            local target_home target_shell
            target_home="$(echo "$target" | jq -r '.home // ""')"
            target_shell="$(echo "$target" | jq -r '.shell // ""')"
            conflict_resolve "user" "$username" \
                "uid=$uid, shell=$shell, home=$home" \
                "uid=$target_uid, shell=$target_shell, home=$target_home"
            action="$CONFLICT_RESULT_ACTION"
        fi

        case "$action" in
            skip)
                log_action "Skipped existing user '$username' per conflict resolution"
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                continue
                ;;
            rename)
                username="${username}_restored"
                action="create"
                ;;
        esac

        # Resolve primary group id on target.
        local primary_group_id=""
        if [[ -n "$group_name" ]]; then
            local tg
            tg="$(target_group_by_name "$group_name")"
            if [[ "$tg" != "null" ]]; then
                primary_group_id="$(echo "$tg" | jq -r '.id')"
            else
                log_warn "Primary group '$group_name' for user '$username' not found on target; TrueNAS will assign a default."
            fi
        fi

        # Resolve auxiliary groups (backup gids -> names -> target ids).
        local aux_ids_json="[]"
        local backup_gid
        for backup_gid in $(echo "$aux_gids" | jq -r '.[]'); do
            local gname
            gname="$(echo "$backup_gid_to_name" | jq -r --arg g "$backup_gid" '.[$g] // empty')"
            [[ -z "$gname" ]] && continue
            local tg
            tg="$(target_group_by_name "$gname")"
            if [[ "$tg" != "null" ]]; then
                local tgid
                tgid="$(echo "$tg" | jq -r '.id')"
                aux_ids_json="$(echo "$aux_ids_json" | jq --argjson id "$tgid" '. + [$id]')"
            fi
        done

        # Home directory strategy.
        policy_resolve_home "$HOME_STRATEGY" "$home" "$username"
        local resolved_home="$POLICY_RESULT_HOME"
        local resolved_home_create="$POLICY_RESULT_HOME_CREATE"

        # Shell fallback.
        local shell_exists resolved_shell
        shell_exists="$(remote_path_exists "$shell" -x)"
        resolved_shell="$(policy_resolve_shell "$shell" "$SHELL_FALLBACK" "$shell_exists")"

        if [[ "$action" == "create" ]]; then
            if [[ "$DRY_RUN" == "1" ]]; then
                log_action "[dry-run] would create user '$username' (uid=$uid, home=${resolved_home:-<default>}, shell=$resolved_shell)"
                continue
            fi

            resolve_password_action "$username"
            if [[ -z "$PASSWORD_FIELDS_JSON" ]]; then
                log_action "Skipped user '$username' at password step"
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                continue
            fi

            local payload result
            payload="$(jq -n \
                --arg username "$username" \
                --argjson uid "$uid" \
                --arg full_name "$full_name" \
                --arg email "$email" \
                --arg home "$resolved_home" \
                --argjson home_create "$resolved_home_create" \
                --arg shell "$resolved_shell" \
                --argjson locked "$locked" \
                --argjson smb "$smb" \
                --argjson sudo_commands "$sudo_cmds" \
                --argjson sudo_commands_nopasswd "$sudo_cmds_np" \
                --arg sshpubkey "$sshpubkey" \
                --argjson password_fields "$PASSWORD_FIELDS_JSON" \
                --argjson groups "$aux_ids_json" \
                '
                {
                    username: $username,
                    uid: $uid,
                    full_name: $full_name,
                    shell: $shell,
                    locked: $locked,
                    smb: $smb,
                    sudo_commands: $sudo_commands,
                    sudo_commands_nopasswd: $sudo_commands_nopasswd,
                    groups: $groups,
                    group_create: true
                }
                + (if $email != "" then {email: $email} else {} end)
                + (if $home != "" then {home: $home, home_create: $home_create} else {} end)
                + (if $sshpubkey != "" then {sshpubkey: $sshpubkey} else {} end)
                + $password_fields
                ')"
            if [[ -n "$primary_group_id" ]]; then
                payload="$(echo "$payload" | jq --argjson g "$primary_group_id" '.group = $g | del(.group_create)')"
            fi

            if result="$(transport_midclt_soft "user.create" "$payload")"; then
                log_action "Created user '$username' (uid=$uid)"
                CREATED_COUNT=$((CREATED_COUNT + 1))
            else
                log_action "FAILED to create user '$username': $result"
                FAILED_COUNT=$((FAILED_COUNT + 1))
                FAILED_REASONS+=("user '$username': $result")
            fi
        elif [[ "$action" == "overwrite" ]]; then
            if [[ "$DRY_RUN" == "1" ]]; then
                log_action "[dry-run] would update user '$username' (uid -> $uid, home=${resolved_home:-<unchanged>}, shell=$resolved_shell)"
                continue
            fi
            local target_id result
            target_id="$(echo "$target" | jq -r '.id')"
            local payload
            payload="$(jq -n \
                --argjson uid "$uid" \
                --arg shell "$resolved_shell" \
                --argjson locked "$locked" \
                --argjson smb "$smb" \
                --argjson sudo_commands "$sudo_cmds" \
                --argjson sudo_commands_nopasswd "$sudo_cmds_np" \
                --argjson groups "$aux_ids_json" \
                '{uid: $uid, shell: $shell, locked: $locked, smb: $smb, sudo_commands: $sudo_commands, sudo_commands_nopasswd: $sudo_commands_nopasswd, groups: $groups}')"
            if [[ -n "$resolved_home" ]]; then
                payload="$(echo "$payload" | jq --arg h "$resolved_home" --argjson hc "$resolved_home_create" '.home = $h | .home_create = $hc')"
            fi
            if result="$(transport_midclt_soft "user.update" "[$target_id, $payload]")"; then
                log_action "Updated user '$username'"
                UPDATED_COUNT=$((UPDATED_COUNT + 1))
            else
                log_action "FAILED to update user '$username': $result"
                FAILED_COUNT=$((FAILED_COUNT + 1))
                FAILED_REASONS+=("user '$username': $result")
            fi
        fi
    done
}

main() {
    parse_args "$@"

    require_cmd ssh
    require_cmd jq

    load_backup "$INPUT_PATH"

    transport_configure "$TARGET_HOST" "$TARGET_USER" "$TARGET_PORT" "$TARGET_IDENTITY"
    transport_check

    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="./restore-logs/${TARGET_HOST}-$(utc_timestamp)"
    fi
    mkdir -p "$OUTPUT_DIR"
    RESTORE_LOG_FILE="$OUTPUT_DIR/restore.log"
    : > "$RESTORE_LOG_FILE"

    fetch_target_state
    preflight_report

    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "Dry run complete. No changes were made."
        exit "$EXIT_OK"
    fi

    if ! confirm "Proceed with restore?" "n"; then
        log_info "Aborted by user."
        exit "$EXIT_OK"
    fi

    restore_groups
    restore_users

    echo ""
    echo "${COLOR_BOLD}Restore summary${COLOR_RESET}"
    echo "  Created: $CREATED_COUNT"
    echo "  Updated: $UPDATED_COUNT"
    echo "  Skipped: $SKIPPED_COUNT"
    echo "  Failed:  $FAILED_COUNT"
    if [[ "$FAILED_COUNT" -gt 0 ]]; then
        echo ""
        echo "Failures:"
        local reason
        for reason in "${FAILED_REASONS[@]}"; do
            echo "  - $reason"
        done
        echo ""
        echo "Full log: $RESTORE_LOG_FILE"
        exit "$EXIT_PARTIAL_SUCCESS"
    fi

    echo "Full log: $RESTORE_LOG_FILE"
    exit "$EXIT_OK"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
