#!/usr/bin/env bash
# lib/conflict.sh - Per-conflict interactive prompt for restore.sh, with an
# "apply to all remaining conflicts" memory so the operator isn't asked the
# same question for every one of a hundred users.
#
# This file must be sourced, not executed.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/conflict.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# Set once the operator answers "apply to all remaining conflicts" (or via
# --yes-to-all-conflicts on the CLI). Once set, conflict_resolve() returns
# it immediately without prompting again.
CONFLICT_APPLY_ALL_ACTION=""

# conflict_set_apply_all: pre-seeds the "apply to all" action, e.g. from
# --yes-to-all-conflicts. Arguments: action (skip|overwrite)
conflict_set_apply_all() {
    local action="$1"
    case "$action" in
        skip|overwrite|rename) CONFLICT_APPLY_ALL_ACTION="$action" ;;
        *) die "Invalid conflict action: $action" "$EXIT_INVALID_ARGS" ;;
    esac
}

# conflict_resolve: presents a single conflict to the operator. Arguments:
#   entity_type   "user" or "group"
#   entity_name   the name in conflict
#   backup_desc   one-line summary of the backup's version of the entity
#   target_desc   one-line summary of the target's current version
#   diff_text     (optional) extra detail shown when the operator picks [d]iff
# Sets CONFLICT_RESULT_ACTION to one of: skip, overwrite, rename.
# Calls die() (exit) immediately if the operator chooses [a]bort.
#
# IMPORTANT: this function communicates its result via the CONFLICT_RESULT_
# ACTION global, and also *updates* CONFLICT_APPLY_ALL_ACTION as a side
# effect when the operator asks to apply a choice to all remaining
# conflicts. It must therefore be called as a plain statement
# (`conflict_resolve ...; use "$CONFLICT_RESULT_ACTION"`), never as
# `x="$(conflict_resolve ...)"` - a command substitution runs the function
# in a subshell, which would silently discard the "apply to all" memory
# after every single call, defeating the entire feature.
CONFLICT_RESULT_ACTION=""
conflict_resolve() {
    local entity_type="$1"
    local entity_name="$2"
    local backup_desc="$3"
    local target_desc="$4"
    local diff_text="${5:-}"

    if [[ -n "$CONFLICT_APPLY_ALL_ACTION" ]]; then
        log_info "Conflict: $entity_type '$entity_name' -> applying remembered action: $CONFLICT_APPLY_ALL_ACTION"
        CONFLICT_RESULT_ACTION="$CONFLICT_APPLY_ALL_ACTION"
        return 0
    fi

    echo "" >&2
    echo "Conflict: $entity_type '$entity_name' already exists on target." >&2
    echo "  Backup:  $backup_desc" >&2
    echo "  Target:  $target_desc" >&2

    if [[ "$ASSUME_YES" == "1" ]] || [[ ! -t 0 ]]; then
        log_warn "Non-interactive: defaulting to 'skip' for this conflict. Use --yes-to-all-conflicts to change this."
        CONFLICT_RESULT_ACTION="skip"
        return 0
    fi

    local reply action
    while true; do
        read -r -p "Action? [s]kip / [o]verwrite / [r]ename-source / [d]iff / [a]bort " reply
        case "$reply" in
            s|S|skip) action="skip"; break ;;
            o|O|overwrite) action="overwrite"; break ;;
            r|R|rename-source|rename) action="rename"; break ;;
            d|D|diff)
                if [[ -n "$diff_text" ]]; then
                    echo "$diff_text" >&2
                else
                    echo "  (no additional detail available beyond Backup/Target above)" >&2
                fi
                continue
                ;;
            a|A|abort) die "Restore aborted by user at conflict on $entity_type '$entity_name'." "$EXIT_GENERAL_ERROR" ;;
            *) echo "Please answer s, o, r, d, or a." >&2 ;;
        esac
    done

    if confirm "Apply to all remaining conflicts?" "n"; then
        CONFLICT_APPLY_ALL_ACTION="$action"
        log_info "Remembering '$action' for all remaining conflicts this run."
    fi

    CONFLICT_RESULT_ACTION="$action"
}
