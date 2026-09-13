#!/usr/bin/env bash
# lib/policy.sh - Home directory and shell resolution policies used by
# restore.sh. Kept free of any SSH/transport dependency so it stays easy to
# reason about and test in isolation: callers perform remote existence
# checks (via lib/transport.sh) and pass the results in as plain booleans.
#
# This file must be sourced, not executed.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/policy.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# Populated by policy_add_home_remap from repeated --home-remap flags.
declare -A POLICY_HOME_REMAP=()

# Set by policy_resolve_home(); the two-value "return" for the resolved
# home path and whether TrueNAS should be asked to create it.
POLICY_RESULT_HOME=""
POLICY_RESULT_HOME_CREATE="false"

# policy_add_home_remap: registers one --home-remap <from>=<to> rule.
# Arguments: rule_string (e.g. "/mnt/tank/home=/mnt/newpool/home")
policy_add_home_remap() {
    local rule="$1"
    local from="${rule%%=*}"
    local to="${rule#*=}"
    if [[ -z "$from" || -z "$to" || "$from" == "$rule" ]]; then
        die "Invalid --home-remap rule (expected FROM=TO): $rule" "$EXIT_INVALID_ARGS"
    fi
    POLICY_HOME_REMAP["$from"]="$to"
}

# policy_apply_remap: applies the first matching --home-remap prefix rule
# to a path. Arguments: original_path. Sets POLICY_REMAP_RESULT (the
# remapped path, or the original path unchanged if nothing matched) and
# POLICY_REMAP_MATCHED (true/false).
#
# IMPORTANT: this function communicates via globals rather than echoing its
# result, and must therefore be called directly (never as
# `x="$(policy_apply_remap ...)"`) - a command substitution runs the
# function in a subshell, so any globals it sets would be silently
# discarded when the subshell exits and the caller would always see stale
# or empty values.
POLICY_REMAP_RESULT=""
POLICY_REMAP_MATCHED="false"
policy_apply_remap() {
    local original_path="$1"
    local from
    POLICY_REMAP_MATCHED="false"
    POLICY_REMAP_RESULT="$original_path"
    for from in "${!POLICY_HOME_REMAP[@]}"; do
        if [[ "$original_path" == "$from"* ]]; then
            local to="${POLICY_HOME_REMAP[$from]}"
            POLICY_REMAP_MATCHED="true"
            POLICY_REMAP_RESULT="${to}${original_path#"$from"}"
            return 0
        fi
    done
}

# policy_resolve_home: decides the home path (if any) and home_create flag
# to send to user.create, per --home-strategy. Arguments:
#   strategy      skip|remap|preserve|prompt
#   backup_home   the home path recorded in the backup
#   username      for prompt-mode messages and logging only
# Sets POLICY_RESULT_HOME and POLICY_RESULT_HOME_CREATE. Does not touch the
# network; any "does the parent exist on target" check is the caller's
# job (see restore.sh's pre-flight validation pass).
policy_resolve_home() {
    local strategy="$1"
    local backup_home="$2"
    local username="$3"

    case "$strategy" in
        skip)
            POLICY_RESULT_HOME=""
            POLICY_RESULT_HOME_CREATE="false"
            ;;
        remap)
            policy_apply_remap "$backup_home"
            if [[ "$POLICY_REMAP_MATCHED" == "true" ]]; then
                POLICY_RESULT_HOME="$POLICY_REMAP_RESULT"
                POLICY_RESULT_HOME_CREATE="true"
            else
                log_warn "No --home-remap rule matched '$backup_home' for user '$username'; falling back to skip (default home)."
                POLICY_RESULT_HOME=""
                POLICY_RESULT_HOME_CREATE="false"
            fi
            ;;
        preserve)
            POLICY_RESULT_HOME="$backup_home"
            POLICY_RESULT_HOME_CREATE="true"
            ;;
        prompt)
            if [[ "$ASSUME_YES" == "1" ]] || [[ ! -t 0 ]]; then
                log_warn "Non-interactive: cannot prompt for home path of '$username'; falling back to skip."
                POLICY_RESULT_HOME=""
                POLICY_RESULT_HOME_CREATE="false"
            else
                local reply
                read -r -p "Home path for '$username' [$backup_home, blank to skip]: " reply
                if [[ -z "$reply" ]]; then
                    POLICY_RESULT_HOME=""
                    POLICY_RESULT_HOME_CREATE="false"
                else
                    # Read by restore.sh after this function returns, not
                    # within this file - hence the lint suppressions below.
                    # shellcheck disable=SC2034
                    POLICY_RESULT_HOME="$reply"
                    # shellcheck disable=SC2034
                    POLICY_RESULT_HOME_CREATE="true"
                fi
            fi
            ;;
        *)
            die "Unknown --home-strategy: $strategy" "$EXIT_INVALID_ARGS"
            ;;
    esac
}

# policy_resolve_shell: decides which shell to use, falling back when the
# backup's shell does not exist on the target. Arguments:
#   backup_shell           shell path recorded in the backup
#   fallback_shell         --shell-fallback value
#   shell_exists_on_target "true" or "false" (caller determines this via
#                          `test -x` over SSH; see restore.sh)
# Echoes the shell path to use.
policy_resolve_shell() {
    local backup_shell="$1"
    local fallback_shell="$2"
    local shell_exists_on_target="$3"

    if [[ -z "$backup_shell" ]]; then
        echo "$fallback_shell"
        return 0
    fi

    if [[ "$shell_exists_on_target" == "true" ]]; then
        echo "$backup_shell"
    else
        log_warn "Shell '$backup_shell' not found on target; substituting fallback '$fallback_shell'."
        echo "$fallback_shell"
    fi
}
