#!/usr/bin/env bash
# lib/report.sh - HTML + Markdown report generation from a backup JSON file.
#
# Password hashes are NEVER rendered, even when contains_hashes=true; only
# their presence/absence is shown ("<hash-present>" / "<hash-absent>").
#
# Template placeholders are substituted using bash's literal ${var//find/rep}
# expansion rather than sed/awk, so arbitrary field content (usernames, full
# names, paths) can never be interpreted as a regex or injected into the
# template structure.
#
# This file must be sourced, not executed.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib/report.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

REPORT_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates" && pwd)"

# report_html_escape: escapes a string for safe inclusion in HTML text.
# Arguments: value. Echoes the escaped value.
report_html_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    value="${value//\'/&#39;}"
    printf '%s' "$value"
}

# report_md_escape: escapes a string for safe inclusion in a Markdown table
# cell. Arguments: value. Echoes the escaped value.
report_md_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//|/\\|}"
    value="${value//$'\n'/ }"
    printf '%s' "$value"
}

# report_render: performs literal placeholder substitution on a template.
# Arguments: template_path, then pairs of "TOKEN" "value" ...
# Echoes the rendered content to stdout.
report_render() {
    local template_path="$1"
    shift
    local content
    content="$(cat "$template_path")"

    while [[ $# -gt 0 ]]; do
        local token="$1"
        local value="$2"
        shift 2
        content="${content//\{\{$token\}\}/$value}"
    done

    printf '%s\n' "$content"
}

# _report_hash_status: echoes "present", "absent", or "n/a" for a user JSON
# object depending on whether it carries a hashes sub-object with data.
# Arguments: none (reads from stdin: one user object as compact JSON on a
# single line, plus the value already embedded by the caller's jq pipeline).
# Implemented inline in the jq pipelines below instead; kept here only as
# documentation of the convention.

# report_build_users_rows_html: builds <tr> rows for the users table.
# Arguments: json_file. Echoes HTML rows to stdout.
report_build_users_rows_html() {
    local json_file="$1"
    while IFS=$'\t' read -r username uid full_name group_name home shell locked smb sudo_count aux_count hash_status; do
        [[ -z "$username" && -z "$uid" ]] && continue
        local badge_locked badge_smb
        if [[ "$locked" == "true" ]]; then badge_locked='<span class="badge badge-yes">locked</span>'; else badge_locked='<span class="badge badge-no">unlocked</span>'; fi
        if [[ "$smb" == "true" ]]; then badge_smb='<span class="badge badge-yes">smb</span>'; else badge_smb='<span class="badge badge-no">off</span>'; fi
        local hash_badge
        case "$hash_status" in
            present) hash_badge='<span class="badge badge-yes">&lt;hash-present&gt;</span>' ;;
            absent) hash_badge='<span class="badge badge-no">&lt;hash-absent&gt;</span>' ;;
            *) hash_badge='<span class="badge badge-no">n/a</span>' ;;
        esac
        printf '        <tr><td>%s</td><td class="mono">%s</td><td>%s</td><td>%s</td><td class="mono">%s</td><td class="mono">%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$(report_html_escape "$username")" \
            "$(report_html_escape "$uid")" \
            "$(report_html_escape "$full_name")" \
            "$(report_html_escape "$group_name")" \
            "$(report_html_escape "$home")" \
            "$(report_html_escape "$shell")" \
            "$badge_locked" \
            "$badge_smb" \
            "$(report_html_escape "$sudo_count")" \
            "$(report_html_escape "$aux_count")" \
            "$hash_badge"
    done < <(_report_users_tsv "$json_file" | tr -d '\r')
}

# report_build_groups_rows_html: builds <tr> rows for the groups table.
# Arguments: json_file. Echoes HTML rows to stdout.
report_build_groups_rows_html() {
    local json_file="$1"
    while IFS=$'\t' read -r name gid smb sudo_count member_count; do
        [[ -z "$name" && -z "$gid" ]] && continue
        local badge_smb
        if [[ "$smb" == "true" ]]; then badge_smb='<span class="badge badge-yes">smb</span>'; else badge_smb='<span class="badge badge-no">off</span>'; fi
        printf '        <tr><td>%s</td><td class="mono">%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$(report_html_escape "$name")" \
            "$(report_html_escape "$gid")" \
            "$badge_smb" \
            "$(report_html_escape "$sudo_count")" \
            "$(report_html_escape "$member_count")"
    done < <(_report_groups_tsv "$json_file" | tr -d '\r')
}

# report_build_users_rows_md: builds Markdown table rows for users.
# Arguments: json_file. Echoes Markdown rows to stdout.
report_build_users_rows_md() {
    local json_file="$1"
    while IFS=$'\t' read -r username uid full_name group_name home shell locked smb sudo_count aux_count hash_status; do
        [[ -z "$username" && -z "$uid" ]] && continue
        local hash_cell
        case "$hash_status" in
            present) hash_cell="<hash-present>" ;;
            absent) hash_cell="<hash-absent>" ;;
            *) hash_cell="n/a" ;;
        esac
        printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
            "$(report_md_escape "$username")" \
            "$(report_md_escape "$uid")" \
            "$(report_md_escape "$full_name")" \
            "$(report_md_escape "$group_name")" \
            "$(report_md_escape "$home")" \
            "$(report_md_escape "$shell")" \
            "$(report_md_escape "$locked")" \
            "$(report_md_escape "$smb")" \
            "$(report_md_escape "$sudo_count")" \
            "$(report_md_escape "$aux_count")" \
            "$(report_md_escape "$hash_cell")"
    done < <(_report_users_tsv "$json_file" | tr -d '\r')
}

# report_build_groups_rows_md: builds Markdown table rows for groups.
# Arguments: json_file. Echoes Markdown rows to stdout.
report_build_groups_rows_md() {
    local json_file="$1"
    while IFS=$'\t' read -r name gid smb sudo_count member_count; do
        [[ -z "$name" && -z "$gid" ]] && continue
        printf '| %s | %s | %s | %s | %s |\n' \
            "$(report_md_escape "$name")" \
            "$(report_md_escape "$gid")" \
            "$(report_md_escape "$smb")" \
            "$(report_md_escape "$sudo_count")" \
            "$(report_md_escape "$member_count")"
    done < <(_report_groups_tsv "$json_file" | tr -d '\r')
}

# _report_users_tsv: emits one TSV line per user: username, uid, full_name,
# group_name, home, shell, locked, smb, sudo_count, aux_count, hash_status.
# Arguments: json_file
_report_users_tsv() {
    local json_file="$1"
    jq -r '
        .users[]? | [
            (.username // ""),
            (.uid // "" | tostring),
            (.full_name // ""),
            (.group_name // (.group // "") | tostring),
            (.home // ""),
            (.shell // ""),
            (.locked // false | tostring),
            (.smb // false | tostring),
            (((.sudo_commands // []) | length) + ((.sudo_commands_nopasswd // []) | length) | tostring),
            ((.groups // []) | length | tostring),
            (if has("hashes") then
                (if ((.hashes.unixhash // "") != "" or (.hashes.smbhash // "") != "") then "present" else "absent" end)
             else "n/a" end)
        ] | join("\t")
    ' "$json_file"
}

# _report_groups_tsv: emits one TSV line per group: name, gid, smb,
# sudo_count, member_count. Arguments: json_file
_report_groups_tsv() {
    local json_file="$1"
    jq -r '
        .groups[]? | [
            (.name // ""),
            (.gid // "" | tostring),
            (.smb // false | tostring),
            (((.sudo_commands // []) | length) + ((.sudo_commands_nopasswd // []) | length) | tostring),
            ((.users // []) | length | tostring)
        ] | join("\t")
    ' "$json_file"
}

# report_generate_html: renders the HTML report from a backup JSON file.
# Arguments: json_file, out_file
report_generate_html() {
    local json_file="$1"
    local out_file="$2"

    log_info "Generating HTML report: $out_file"

    local generated_at source source_host source_version tool_version user_count group_count contains_hashes
    generated_at="$(jq -r '.generated_at' "$json_file")"
    source="$(jq -r '.source' "$json_file")"
    source_host="$(jq -r '.source_host' "$json_file")"
    source_version="$(jq -r '.source_version' "$json_file")"
    tool_version="$(jq -r '.tool_version' "$json_file")"
    user_count="$(jq -r '.users | length' "$json_file")"
    group_count="$(jq -r '.groups | length' "$json_file")"
    contains_hashes="$(jq -r '.contains_hashes' "$json_file")"

    local hash_notice=""
    if [[ "$contains_hashes" == "true" ]]; then
        hash_notice='<div class="notice">This backup was extracted from a configuration database and contains password hashes. This report never displays hash values &mdash; only &lt;hash-present&gt; / &lt;hash-absent&gt; markers. The underlying JSON file is chmod 600.</div>'
    fi

    local users_rows groups_rows
    users_rows="$(report_build_users_rows_html "$json_file")"
    groups_rows="$(report_build_groups_rows_html "$json_file")"

    local rendered
    rendered="$(report_render "$REPORT_TEMPLATE_DIR/report.html.tmpl" \
        "TITLE" "TrueNAS Identity Report - $(report_html_escape "$source_host")" \
        "GENERATED_AT" "$(report_html_escape "$generated_at")" \
        "SOURCE" "$(report_html_escape "$source")" \
        "SOURCE_HOST" "$(report_html_escape "$source_host")" \
        "SOURCE_VERSION" "$(report_html_escape "$source_version")" \
        "TOOL_VERSION" "$(report_html_escape "$tool_version")" \
        "USER_COUNT" "$user_count" \
        "GROUP_COUNT" "$group_count" \
        "HASH_NOTICE" "$hash_notice" \
        "USERS_TABLE_ROWS" "$users_rows" \
        "GROUPS_TABLE_ROWS" "$groups_rows")"

    printf '%s\n' "$rendered" > "$out_file"
    report_chmod "$out_file"
    log_success "Wrote HTML report: $out_file"
}

# report_generate_markdown: renders the Markdown report from a backup JSON
# file. Arguments: json_file, out_file
report_generate_markdown() {
    local json_file="$1"
    local out_file="$2"

    log_info "Generating Markdown report: $out_file"

    local generated_at source source_host source_version tool_version user_count group_count contains_hashes
    generated_at="$(jq -r '.generated_at' "$json_file")"
    source="$(jq -r '.source' "$json_file")"
    source_host="$(jq -r '.source_host' "$json_file")"
    source_version="$(jq -r '.source_version' "$json_file")"
    tool_version="$(jq -r '.tool_version' "$json_file")"
    user_count="$(jq -r '.users | length' "$json_file")"
    group_count="$(jq -r '.groups | length' "$json_file")"
    contains_hashes="$(jq -r '.contains_hashes' "$json_file")"

    local hash_notice=""
    if [[ "$contains_hashes" == "true" ]]; then
        hash_notice="> **Note:** This backup was extracted from a configuration database and contains password hashes. This report never displays hash values, only \`<hash-present>\` / \`<hash-absent>\` markers. The underlying JSON file is chmod 600."
    fi

    local users_rows groups_rows
    users_rows="$(report_build_users_rows_md "$json_file")"
    groups_rows="$(report_build_groups_rows_md "$json_file")"

    local rendered
    rendered="$(report_render "$REPORT_TEMPLATE_DIR/report.md.tmpl" \
        "GENERATED_AT" "$generated_at" \
        "SOURCE" "$source" \
        "SOURCE_HOST" "$source_host" \
        "SOURCE_VERSION" "$source_version" \
        "TOOL_VERSION" "$tool_version" \
        "USER_COUNT" "$user_count" \
        "GROUP_COUNT" "$group_count" \
        "HASH_NOTICE" "$hash_notice" \
        "USERS_TABLE_MD" "$users_rows" \
        "GROUPS_TABLE_MD" "$groups_rows")"

    printf '%s\n' "$rendered" > "$out_file"
    report_chmod "$out_file"
    log_success "Wrote Markdown report: $out_file"
}
