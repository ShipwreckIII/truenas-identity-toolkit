#!/usr/bin/env bash
# lib/transport.sh - SSH + midclt transport abstraction.
#
# Every live-system interaction in this toolkit goes through midclt over SSH.
# We deliberately never call the TrueNAS REST API (/api/v2.0): it is
# deprecated as of SCALE 25.04 "Fangtooth" and scheduled for removal in a
# future release. midclt is the same call surface the WebUI itself uses and
# is expected to remain supported for the life of SCALE. See
# docs/ARCHITECTURE.md for the full rationale.
#
# This file must be sourced, not executed.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/transport.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Globals populated by transport_configure()
# ---------------------------------------------------------------------------

TRANSPORT_HOST=""
TRANSPORT_USER="root"
TRANSPORT_PORT="22"
TRANSPORT_IDENTITY=""
declare -a TRANSPORT_SSH_OPTS=()

# transport_configure: sets up connection parameters for subsequent calls.
# Arguments: host, user, port, [identity_path]
transport_configure() {
    TRANSPORT_HOST="$1"
    TRANSPORT_USER="${2:-root}"
    TRANSPORT_PORT="${3:-22}"
    TRANSPORT_IDENTITY="${4:-}"

    TRANSPORT_SSH_OPTS=(
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
        -p "$TRANSPORT_PORT"
    )
    if [[ -n "$TRANSPORT_IDENTITY" ]]; then
        TRANSPORT_SSH_OPTS+=(-i "$TRANSPORT_IDENTITY")
    fi
}

# transport_target: echoes the user@host string for logging. Arguments: none.
transport_target() {
    echo "${TRANSPORT_USER}@${TRANSPORT_HOST}:${TRANSPORT_PORT}"
}

# transport_check: verifies SSH connectivity and that midclt is reachable on
# the remote host. Arguments: none. Returns: 0 on success, dies otherwise.
transport_check() {
    local target
    target="$(transport_target)"
    log_info "Checking SSH connectivity to $target ..."

    if ! ssh "${TRANSPORT_SSH_OPTS[@]}" "${TRANSPORT_USER}@${TRANSPORT_HOST}" true 2>/tmp/tnit_ssh_check.$$; then
        local err
        err="$(cat /tmp/tnit_ssh_check.$$ 2>/dev/null || true)"
        rm -f /tmp/tnit_ssh_check.$$
        die "SSH connection to $target failed. $err" "$EXIT_CONNECTIVITY_FAILURE"
    fi
    rm -f /tmp/tnit_ssh_check.$$

    log_info "Checking midclt availability on $target ..."
    if ! ssh "${TRANSPORT_SSH_OPTS[@]}" "${TRANSPORT_USER}@${TRANSPORT_HOST}" \
        "command -v midclt >/dev/null 2>&1"; then
        die "midclt not found on $target. Is this a TrueNAS SCALE system?" "$EXIT_CONNECTIVITY_FAILURE"
    fi

    log_success "Connectivity to $target verified."
    return 0
}

# transport_midclt: runs 'midclt call <method> [json_args]' on the remote
# host and echoes stdout (expected to be JSON). Arguments: method, [json_args]
# Returns: 0 on success; dies on failure so callers can assume valid JSON.
transport_midclt() {
    local method="$1"
    local json_args="${2:-}"
    local remote_cmd
    local out
    local rc

    if [[ -n "$json_args" ]]; then
        # Single-quote the JSON payload for the remote shell; escape any
        # single quotes it might contain.
        local escaped_json="${json_args//\'/\'\\\'\'}"
        remote_cmd="midclt call ${method} '${escaped_json}'"
    else
        remote_cmd="midclt call ${method}"
    fi

    log_debug "Remote: $remote_cmd"

    if ! out="$(ssh "${TRANSPORT_SSH_OPTS[@]}" "${TRANSPORT_USER}@${TRANSPORT_HOST}" "$remote_cmd" 2>&1)"; then
        rc=$?
        die "midclt call '${method}' failed on $(transport_target): $out" "$EXIT_GENERAL_ERROR"
        return "$rc"
    fi

    echo "$out"
    return 0
}

# transport_midclt_soft: like transport_midclt but does not die on failure.
# Arguments: method, [json_args]. Echoes stdout+stderr; returns midclt's
# actual exit code so callers can handle failures gracefully (e.g. optional
# fields, per-user operations during restore).
transport_midclt_soft() {
    local method="$1"
    local json_args="${2:-}"
    local remote_cmd
    local out
    local rc=0

    if [[ -n "$json_args" ]]; then
        local escaped_json="${json_args//\'/\'\\\'\'}"
        remote_cmd="midclt call ${method} '${escaped_json}'"
    else
        remote_cmd="midclt call ${method}"
    fi

    log_debug "Remote (soft): $remote_cmd"
    out="$(ssh "${TRANSPORT_SSH_OPTS[@]}" "${TRANSPORT_USER}@${TRANSPORT_HOST}" "$remote_cmd" 2>&1)" || rc=$?
    echo "$out"
    return "$rc"
}

# transport_exec: runs an arbitrary shell command on the remote host (used
# for things midclt doesn't cover, e.g. `test -x <shell>`).
# Arguments: command_string. Returns: remote command's exit code.
transport_exec() {
    local remote_cmd="$1"
    ssh "${TRANSPORT_SSH_OPTS[@]}" "${TRANSPORT_USER}@${TRANSPORT_HOST}" "$remote_cmd"
}

# transport_exec_out: like transport_exec but captures and echoes stdout.
# Arguments: command_string. Returns: remote command's exit code.
transport_exec_out() {
    local remote_cmd="$1"
    ssh "${TRANSPORT_SSH_OPTS[@]}" "${TRANSPORT_USER}@${TRANSPORT_HOST}" "$remote_cmd"
}
