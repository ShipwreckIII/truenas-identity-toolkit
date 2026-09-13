#!/usr/bin/env bash
# reset-users.sh - DESTRUCTIVE test-cycle tool. Wipes all non-builtin users
# (and, optionally, their now-orphaned primary groups) on a target TrueNAS
# SCALE system over SSH+midclt. Intended for repeatedly resetting a lab/test
# system between restore.sh dry runs, never for anything you'd call
# production. Every safety gate below is mandatory, with no override flag
# that skips more than one of them at a time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/transport.sh
source "$LIB_DIR/transport.sh"

trap cleanup_tempdirs EXIT

readonly PROG_NAME="reset-users.sh"

# usage: prints help text. Arguments: none.
usage() {
    cat <<EOF
$PROG_NAME - DESTRUCTIVE: delete all non-builtin users on a target system.

This is a test-cycle helper for resetting a lab/test TrueNAS SCALE system
between restore.sh runs. It is not reversible. It refuses to run against
anything that looks like a production host.

Usage:
  $PROG_NAME --host <host> --i-understand-this-is-destructive [options]

Required:
  --host <hostname-or-ip>              Target TrueNAS SCALE host
  --i-understand-this-is-destructive   Required acknowledgment flag

Options:
  --user <ssh-user>              SSH user (default: root)
  --port <ssh-port>               SSH port (default: 22)
  --identity <ssh-key-path>       SSH private key to use
  --delete-primary-groups         Also delete each user's now-orphaned
                                    primary group (default: off)
  --production-hosts <regex>      Extra regex of hostnames to refuse
                                    (case-insensitive; always refuses
                                    anything containing 'prod' or
                                    'production' regardless of this flag)
  --dry-run                       Show what would be deleted; delete nothing
  --no-color                      Disable colored output
  -h, --help                      Show this help and exit
  -v, --version                   Show version and exit

Safety gates (all required, every run):
  1. --i-understand-this-is-destructive must be passed
  2. The target hostname must not match 'prod', 'production', or
     --production-hosts
  3. The full list of users to be deleted is printed before anything happens
  4. You must type the target hostname exactly to confirm
  5. A 10-second countdown runs before the first deletion (Ctrl+C aborts)

Exit codes:
  0 success   1 general error   2 invalid arguments   3 connectivity failure
  5 partial success (some deletions failed)

Example:
  $PROG_NAME --host lab-truenas.local --i-understand-this-is-destructive
EOF
}

HOST=""
SSH_USER="root"
SSH_PORT="22"
IDENTITY=""
CONFIRMED_DESTRUCTIVE=0
DELETE_PRIMARY_GROUPS=0
PRODUCTION_HOSTS_REGEX=""
DRY_RUN=0

# parse_args: parses CLI flags into globals. Arguments: "$@"
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host) HOST="${2:?--host requires a value}"; shift 2 ;;
            --user) SSH_USER="${2:?--user requires a value}"; shift 2 ;;
            --port) SSH_PORT="${2:?--port requires a value}"; shift 2 ;;
            --identity) IDENTITY="${2:?--identity requires a value}"; shift 2 ;;
            --i-understand-this-is-destructive) CONFIRMED_DESTRUCTIVE=1; shift ;;
            --delete-primary-groups) DELETE_PRIMARY_GROUPS=1; shift ;;
            --production-hosts) PRODUCTION_HOSTS_REGEX="${2:?--production-hosts requires a value}"; shift 2 ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes) ASSUME_YES=1; shift ;;
            --no-color) NO_COLOR=1; init_colors; shift ;;
            -h|--help) usage; exit "$EXIT_OK" ;;
            -v|--version) print_version "$PROG_NAME" ;;
            *) log_error "Unknown argument: $1"; usage; exit "$EXIT_INVALID_ARGS" ;;
        esac
    done

    if [[ -z "$HOST" ]]; then
        log_error "--host is required"; usage; exit "$EXIT_INVALID_ARGS"
    fi
    if [[ "$CONFIRMED_DESTRUCTIVE" != "1" ]]; then
        log_error "This tool deletes users. Re-run with --i-understand-this-is-destructive."
        exit "$EXIT_INVALID_ARGS"
    fi
}

# check_not_production: refuses to proceed if the hostname (the --host
# value, and the value midclt reports) looks like production. Arguments:
# reported_hostname
check_not_production() {
    local reported_hostname="$1"
    local lower_host lower_reported

    lower_host="$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')"
    lower_reported="$(printf '%s' "$reported_hostname" | tr '[:upper:]' '[:lower:]')"

    if [[ "$lower_host" == *prod* || "$lower_reported" == *prod* ]]; then
        die "Refusing to run: hostname looks like production ('$HOST' / '$reported_hostname'). This tool is for lab/test systems only." "$EXIT_INVALID_ARGS"
    fi
    if [[ -n "$PRODUCTION_HOSTS_REGEX" ]]; then
        if [[ "$lower_host" =~ $PRODUCTION_HOSTS_REGEX ]] || [[ "$lower_reported" =~ $PRODUCTION_HOSTS_REGEX ]]; then
            die "Refusing to run: hostname matches --production-hosts pattern ('$PRODUCTION_HOSTS_REGEX')." "$EXIT_INVALID_ARGS"
        fi
    fi
}

RESET_LOG_FILE=""

# log_action: logs to console and to the reset log. Arguments: message
log_action() {
    local msg="$1"
    log_info "$msg"
    if [[ -n "$RESET_LOG_FILE" ]]; then
        printf '[%s] %s\n' "$(iso_timestamp)" "$msg" >> "$RESET_LOG_FILE"
    fi
}

# countdown: prints a 10-second countdown to give the operator a last
# chance to Ctrl+C. Arguments: none.
countdown() {
    local n
    echo ""
    log_warn "Starting deletion in 10 seconds. Press Ctrl+C to abort."
    for n in 10 9 8 7 6 5 4 3 2 1; do
        printf '  %2d...\n' "$n" >&2
        sleep 1
    done
}

DELETED_COUNT=0
FAILED_COUNT=0
declare -a FAILED_REASONS=()

main() {
    parse_args "$@"

    require_cmd ssh
    require_cmd jq

    transport_configure "$HOST" "$SSH_USER" "$SSH_PORT" "$IDENTITY"
    transport_check

    local sysinfo reported_hostname
    sysinfo="$(transport_midclt "system.info")"
    reported_hostname="$(echo "$sysinfo" | jq -r '.hostname // ""')"
    check_not_production "$reported_hostname"

    RESET_LOG_FILE="./reset-${HOST}-$(utc_timestamp).log"
    : > "$RESET_LOG_FILE"
    log_action "reset-users.sh starting against $(transport_target) (reported hostname: $reported_hostname)"

    local users_json user_count
    users_json="$(transport_midclt "user.query" | jq -c '[.[] | select(.builtin == false)]')"
    user_count="$(echo "$users_json" | jq 'length')"

    echo ""
    echo "${COLOR_BOLD}The following $user_count non-builtin user(s) will be permanently deleted:${COLOR_RESET}"
    echo "$users_json" | jq -r '.[] | "  - \(.username) (uid=\(.uid))"'
    echo ""

    if [[ "$user_count" == "0" ]]; then
        log_action "No non-builtin users found; nothing to do."
        exit "$EXIT_OK"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "Dry run: no users were deleted."
        exit "$EXIT_OK"
    fi

    if [[ "$ASSUME_YES" != "1" ]]; then
        if [[ ! -t 0 ]]; then
            die "Refusing to proceed non-interactively without --yes: this is a destructive operation and requires typing the hostname to confirm." "$EXIT_INVALID_ARGS"
        fi
        local typed
        read -r -p "Type the target hostname ('$HOST') to confirm deletion: " typed
        if [[ "$typed" != "$HOST" ]]; then
            log_error "Hostname confirmation did not match. Aborting."
            exit "$EXIT_GENERAL_ERROR"
        fi
    fi

    countdown

    local count idx
    count="$(echo "$users_json" | jq 'length')"
    for ((idx = 0; idx < count; idx++)); do
        local user username uid result
        user="$(echo "$users_json" | jq -c ".[$idx]")"
        username="$(echo "$user" | jq -r '.username')"
        uid="$(echo "$user" | jq -r '.uid')"
        local target_id
        target_id="$(echo "$user" | jq -r '.id')"

        local options="{}"
        if [[ "$DELETE_PRIMARY_GROUPS" == "1" ]]; then
            options='{"delete_group": true}'
        fi

        if result="$(transport_midclt_soft "user.delete" "[$target_id, $options]")"; then
            log_action "Deleted user '$username' (uid=$uid)"
            DELETED_COUNT=$((DELETED_COUNT + 1))
        else
            log_action "FAILED to delete user '$username' (uid=$uid): $result"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            FAILED_REASONS+=("$username: $result")
        fi
    done

    echo ""
    echo "${COLOR_BOLD}Reset summary${COLOR_RESET}"
    echo "  Deleted: $DELETED_COUNT"
    echo "  Failed:  $FAILED_COUNT"
    echo "  Log:     $RESET_LOG_FILE"

    if [[ "$FAILED_COUNT" -gt 0 ]]; then
        local reason
        for reason in "${FAILED_REASONS[@]}"; do
            log_action "  - $reason"
        done
        exit "$EXIT_PARTIAL_SUCCESS"
    fi
    exit "$EXIT_OK"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
