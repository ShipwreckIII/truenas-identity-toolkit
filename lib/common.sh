#!/usr/bin/env bash
# lib/common.sh - Logging, prompts, error handling, colors, and misc shared
# helpers used by every script in the toolkit.
#
# Source this file after setting SCRIPT_DIR in the calling script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/common.sh
#   source "$SCRIPT_DIR/../lib/common.sh"
#
# This file must not be executed directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/common.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# Bash >=5.2 enables 'patsub_replacement' by default, which makes a literal
# '&' in the replacement side of ${var//pattern/replacement} expand to the
# matched text (sed-like behavior). This toolkit relies on plain, literal
# string substitution (see lib/report.sh's template rendering, and any
# --home-remap value handling in lib/policy.sh) for values that may contain
# '&' (HTML entities, arbitrary paths). Disable it here so substitution stays
# purely literal; this is a silent no-op on bash <5.2, where the option does
# not exist and the old literal behavior is already the default.
shopt -u patsub_replacement 2>/dev/null || true

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

TOOLKIT_VERSION="0.1.0"
NO_COLOR="${NO_COLOR:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# Exit code convention used across every script in this toolkit. Several
# of these are only ever referenced from the bin/*.sh scripts that source
# this file, not from within common.sh itself, so shellcheck cannot see
# the usage when checking this file in isolation.
readonly EXIT_OK=0
readonly EXIT_GENERAL_ERROR=1
# shellcheck disable=SC2034
readonly EXIT_INVALID_ARGS=2
# shellcheck disable=SC2034
readonly EXIT_CONNECTIVITY_FAILURE=3
# shellcheck disable=SC2034
readonly EXIT_VALIDATION_FAILURE=4
# shellcheck disable=SC2034
readonly EXIT_PARTIAL_SUCCESS=5

# ---------------------------------------------------------------------------
# Color setup
# ---------------------------------------------------------------------------

# init_colors: sets COLOR_* globals based on TTY detection and --no-color.
# Arguments: none. Returns: 0 always.
init_colors() {
    if [[ "$NO_COLOR" == "1" ]] || [[ ! -t 1 ]]; then
        COLOR_RED=""
        COLOR_GREEN=""
        COLOR_YELLOW=""
        COLOR_BLUE=""
        # shellcheck disable=SC2034 # used by bin/*.sh section headers, not here
        COLOR_BOLD=""
        COLOR_RESET=""
    else
        COLOR_RED=$'\033[0;31m'
        COLOR_GREEN=$'\033[0;32m'
        COLOR_YELLOW=$'\033[0;33m'
        COLOR_BLUE=$'\033[0;34m'
        # shellcheck disable=SC2034 # used by bin/*.sh section headers, not here
        COLOR_BOLD=$'\033[1m'
        COLOR_RESET=$'\033[0m'
    fi
}
init_colors

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# _log_ts: prints an ISO-8601 UTC timestamp. Arguments: none. Returns: 0.
_log_ts() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# log_info: prints an informational message to stderr. Arguments: message...
log_info() {
    local msg="$*"
    printf '%s[%s] INFO:%s  %s\n' "$COLOR_BLUE" "$(_log_ts)" "$COLOR_RESET" "$msg" >&2
}

# log_warn: prints a warning message to stderr. Arguments: message...
log_warn() {
    local msg="$*"
    printf '%s[%s] WARN:%s  %s\n' "$COLOR_YELLOW" "$(_log_ts)" "$COLOR_RESET" "$msg" >&2
}

# log_error: prints an error message to stderr. Arguments: message...
log_error() {
    local msg="$*"
    printf '%s[%s] ERROR:%s %s\n' "$COLOR_RED" "$(_log_ts)" "$COLOR_RESET" "$msg" >&2
}

# log_debug: prints a debug message to stderr only when TOOLKIT_DEBUG=1.
# Arguments: message...
log_debug() {
    local msg="$*"
    if [[ "${TOOLKIT_DEBUG:-0}" == "1" ]]; then
        printf '[%s] DEBUG: %s\n' "$(_log_ts)" "$msg" >&2
    fi
}

# log_success: prints a success message to stderr. Arguments: message...
log_success() {
    local msg="$*"
    printf '%s[%s] OK:%s    %s\n' "$COLOR_GREEN" "$(_log_ts)" "$COLOR_RESET" "$msg" >&2
}

# die: logs an error and exits with the given code (default: general error).
# Arguments: message, [exit_code]
die() {
    local msg="$1"
    local code="${2:-$EXIT_GENERAL_ERROR}"
    log_error "$msg"
    exit "$code"
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

# confirm: asks a yes/no question with a default. Honors ASSUME_YES=1 for
# non-interactive runs. Arguments: prompt_text, [default:y|n]
# Returns: 0 for yes, 1 for no.
confirm() {
    local prompt_text="$1"
    local default="${2:-n}"
    local suffix="[y/N]"
    local reply

    [[ "$default" == "y" ]] && suffix="[Y/n]"

    if [[ "$ASSUME_YES" == "1" ]]; then
        log_info "$prompt_text $suffix -> auto-yes (--yes)"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_warn "$prompt_text $suffix -> non-interactive shell, using default ($default)"
        [[ "$default" == "y" ]] && return 0 || return 1
    fi

    read -r -p "$prompt_text $suffix " reply
    reply="${reply:-$default}"
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# prompt_value: asks for a free-text value with a default. Arguments:
# prompt_text, default_value. Echoes the resulting value to stdout.
prompt_value() {
    local prompt_text="$1"
    local default_value="${2:-}"
    local reply

    if [[ "$ASSUME_YES" == "1" ]] || [[ ! -t 0 ]]; then
        echo "$default_value"
        return 0
    fi

    read -r -p "$prompt_text [$default_value]: " reply
    echo "${reply:-$default_value}"
}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------

# require_cmd: dies if a required external command is not on PATH.
# Arguments: command_name, [hint_message]
require_cmd() {
    local cmd_name="$1"
    local hint="${2:-}"
    if ! command -v "$cmd_name" >/dev/null 2>&1; then
        local msg="Required command not found: $cmd_name"
        [[ -n "$hint" ]] && msg="$msg ($hint)"
        die "$msg" "$EXIT_GENERAL_ERROR"
    fi
}

# ---------------------------------------------------------------------------
# Temp file / cleanup helpers
# ---------------------------------------------------------------------------

# TOOLKIT_TEMP_DIRS is populated by mktempdir and drained by cleanup_tempdirs,
# which callers should register once via `trap cleanup_tempdirs EXIT`.
declare -a TOOLKIT_TEMP_DIRS=()

# mktempdir: creates a temp directory and registers it for auto-cleanup on
# exit (the caller must `trap cleanup_tempdirs EXIT` once, near the top of
# the script). Arguments: [prefix]. Echoes the path to stdout.
mktempdir() {
    local prefix="${1:-tnit}"
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")"
    TOOLKIT_TEMP_DIRS+=("$dir")
    echo "$dir"
}

# cleanup_tempdirs: removes every directory registered via mktempdir.
# Arguments: none. Intended for use as an EXIT trap.
#
# IMPORTANT: when used via `trap cleanup_tempdirs EXIT`, this function's own
# exit status becomes the script's final exit status, overriding whatever
# was passed to `exit N`. It must therefore always end by explicitly
# returning 0 rather than letting a (possibly failing) test be its last
# command.
cleanup_tempdirs() {
    local dir
    for dir in "${TOOLKIT_TEMP_DIRS[@]:-}"; do
        if [[ -n "$dir" && -d "$dir" ]]; then
            rm -rf -- "$dir"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------

# utc_timestamp: prints a filesystem-safe UTC timestamp (YYYYmmddTHHMMSSZ).
# Arguments: none.
utc_timestamp() {
    date -u +"%Y%m%dT%H%M%SZ"
}

# iso_timestamp: prints an ISO-8601 UTC timestamp. Arguments: none.
iso_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# print_version: prints the standard "<tool> <version>" banner and exits 0.
# Arguments: tool_name
print_version() {
    local tool_name="$1"
    echo "$tool_name (truenas-identity-toolkit) $TOOLKIT_VERSION"
    exit "$EXIT_OK"
}

# secure_chmod: chmod 600 a file that contains sensitive data (hashes).
# Arguments: file_path
secure_chmod() {
    local file_path="$1"
    chmod 600 "$file_path" 2>/dev/null || log_warn "Could not chmod 600 $file_path"
}

# report_chmod: chmod 644 a generated report file. Arguments: file_path
report_chmod() {
    local file_path="$1"
    chmod 644 "$file_path" 2>/dev/null || log_warn "Could not chmod 644 $file_path"
}
