#!/usr/bin/env bash
# lib/schema.sh - JSON schema version constant + validation helpers for
# backup JSON files (see docs/FIELD-REFERENCE.md for the full schema).
#
# This file must be sourced, not executed.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/schema.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# Current schema version this build of the toolkit produces and expects.
readonly SCHEMA_CURRENT_VERSION=1

# schema_new_document: builds an empty backup document skeleton with the
# required header fields, given as arguments, and echoes it to stdout.
# Arguments: source (api|config-db), source_host, source_version,
#            contains_hashes (true|false)
schema_new_document() {
    local source="$1"
    local source_host="$2"
    local source_version="$3"
    local contains_hashes="$4"

    jq -n \
        --argjson schema "$SCHEMA_CURRENT_VERSION" \
        --arg generated_at "$(iso_timestamp)" \
        --arg source "$source" \
        --arg source_host "$source_host" \
        --arg source_version "$source_version" \
        --arg tool_version "$TOOLKIT_VERSION" \
        --argjson contains_hashes "$contains_hashes" \
        '{
            schema: $schema,
            generated_at: $generated_at,
            source: $source,
            source_host: $source_host,
            source_version: $source_version,
            tool_version: $tool_version,
            contains_hashes: $contains_hashes,
            groups: [],
            users: []
        }'
}

# schema_validate: validates a backup JSON file against the current schema.
# Arguments: file_path
# Returns: 0 if valid. On failure, prints specific problems to stderr and
# returns 4 (EXIT_VALIDATION_FAILURE).
schema_validate() {
    local file_path="$1"
    local -a problems=()

    if [[ ! -f "$file_path" ]]; then
        log_error "Schema validation: file not found: $file_path"
        return "$EXIT_VALIDATION_FAILURE"
    fi

    if ! jq empty "$file_path" >/dev/null 2>&1; then
        log_error "Schema validation: $file_path is not valid JSON"
        return "$EXIT_VALIDATION_FAILURE"
    fi

    local field
    for field in schema generated_at source source_host source_version tool_version contains_hashes groups users; do
        if ! jq -e --arg f "$field" 'has($f)' "$file_path" >/dev/null 2>&1; then
            problems+=("missing top-level field: $field")
        fi
    done

    if [[ ${#problems[@]} -eq 0 ]]; then
        local doc_schema
        doc_schema="$(jq -r '.schema' "$file_path")"
        if [[ "$doc_schema" != "$SCHEMA_CURRENT_VERSION" ]]; then
            if [[ "$doc_schema" =~ ^[0-9]+$ ]] && [[ "$doc_schema" -lt "$SCHEMA_CURRENT_VERSION" ]]; then
                problems+=("schema version $doc_schema is older than current ($SCHEMA_CURRENT_VERSION); no migration path is implemented yet")
            else
                problems+=("unsupported schema version: $doc_schema (expected $SCHEMA_CURRENT_VERSION)")
            fi
        fi

        if ! jq -e '.groups | type == "array"' "$file_path" >/dev/null 2>&1; then
            problems+=("'groups' must be an array")
        fi
        if ! jq -e '.users | type == "array"' "$file_path" >/dev/null 2>&1; then
            problems+=("'users' must be an array")
        fi

        # Spot-check required per-user fields on the first offending entry.
        local missing_user_field
        missing_user_field="$(jq -r '
            [.users[]? | select((has("username") and has("uid")) | not)] | length
        ' "$file_path" 2>/dev/null || echo 0)"
        if [[ "$missing_user_field" != "0" ]]; then
            problems+=("$missing_user_field user entr(y/ies) missing required 'username' or 'uid' field")
        fi

        local missing_group_field
        missing_group_field="$(jq -r '
            [.groups[]? | select((has("name") and has("gid")) | not)] | length
        ' "$file_path" 2>/dev/null || echo 0)"
        if [[ "$missing_group_field" != "0" ]]; then
            problems+=("$missing_group_field group entr(y/ies) missing required 'name' or 'gid' field")
        fi
    fi

    if [[ ${#problems[@]} -gt 0 ]]; then
        log_error "Schema validation failed for $file_path:"
        local p
        for p in "${problems[@]}"; do
            log_error "  - $p"
        done
        return "$EXIT_VALIDATION_FAILURE"
    fi

    log_debug "Schema validation passed for $file_path"
    return 0
}

# schema_source: echoes the 'source' field (api|config-db) of a backup file.
# Arguments: file_path
schema_source() {
    jq -r '.source' "$1"
}

# schema_contains_hashes: echoes "true" or "false". Arguments: file_path
schema_contains_hashes() {
    jq -r '.contains_hashes' "$1"
}
