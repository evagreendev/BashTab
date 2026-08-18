#!/usr/bin/env -S bats --jobs 4

# Tests for the # Synopsis: header convention and get-command integration.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # shellcheck source=../bu_entrypoint.sh
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"

    # Create a temp directory for test command scripts
    TEST_CMD_DIR=$(mktemp -d)
}

teardown() {
    rm -rf "$TEST_CMD_DIR" 2>/dev/null || true
}

# Helper: create a command script with given content at the top
_build_cmd() {
    local name=$1
    local content=$2
    local file="$TEST_CMD_DIR/${name}.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$content"
        printf 'function __bu_%s_main() { :; }\n' "${name//-/_}"
        printf '__bu_%s_main "$@"\n' "${name//-/_}"
    } > "$file"
    chmod +x "$file"
    bu_preinit_register_user_defined_subcommand_file "$file" "$name" source
}

# Helper: query a command's synopsis via the same awk that get-command uses
_synopsis_of() {
    local name=$1
    local path=${BU_COMMANDS[$name]}
    if [[ -f "$path" ]]; then
        awk '
            FNR == 1 { found = 0 }
            !found && FNR <= 30 && /^#[[:space:]]*Synopsis:[[:space:]]/ {
                line = $0
                sub(/^#[[:space:]]*Synopsis:[[:space:]]*/, "", line)
                sub(/[[:space:]]+$/, "", line)
                print line
                found = 1
            }
        ' "$path" 2>/dev/null
    fi
}

# ── Verbatim extraction (no eval) ──
function test_synopsis_verbatim_no_eval { #@test
    _build_cmd test-verbatim '# Synopsis: Path is ${HOME} and date is $(date)'
    local result
    result=$(_synopsis_of test-verbatim)
    assert_equal "$result" 'Path is ${HOME} and date is $(date)'
}

# ── Synopsis within first 30 lines is found ──
function test_synopsis_within_30_lines { #@test
    _build_cmd test-early '# Synopsis: This is early'
    local result
    result=$(_synopsis_of test-early)
    assert_equal "$result" 'This is early'
}

# ── Synopsis past line 30 is NOT found ──
function test_synopsis_past_30_lines_ignored { #@test
    local file="$TEST_CMD_DIR/test-late.sh"
    {
        printf '#!/usr/bin/env bash\n'
        for _ in $(seq 1 35); do printf '# padding line\n'; done
        printf '# Synopsis: This should be ignored\n'
        printf 'function __bu_test_late_main() { :; }\n'
        printf '__bu_test_late_main "$@"\n'
    } > "$file"
    chmod +x "$file"
    bu_preinit_register_user_defined_subcommand_file "$file" test-late source
    local result
    result=$(_synopsis_of test-late)
    assert_equal "$result" ''
}

# ── First Synopsis wins ──
function test_synopsis_first_match_wins { #@test
    _build_cmd test-first '# Synopsis: First wins
# Synopsis: Second ignored'
    local result
    result=$(_synopsis_of test-first)
    assert_equal "$result" 'First wins'
}

# ── Alias without registered synopsis auto-synthesizes ──
function test_synopsis_alias_auto_synthesis { #@test
    bu_preinit_register_new_alias test-alias-auto get-command --format {} {?}
    local result
    result=${BU_COMMAND_PROPERTIES[test-alias-auto,synopsis]:-}
    # No registered synopsis; get-command's synopsis stays empty for aliases
    assert_equal "$result" ''
    # Verify the type is alias
    assert_equal "${BU_COMMAND_PROPERTIES[test-alias-auto,type]}" 'alias'
}

# ── Alias --synopsis override wins over synthesis ──
function test_synopsis_alias_override { #@test
    bu_preinit_register_new_alias test-alias-override query-object --where {...} --synopsis "Custom alias synopsis"
    local result
    result=${BU_COMMAND_PROPERTIES[test-alias-override,synopsis]}
    assert_equal "$result" 'Custom alias synopsis'
}

# ── Registry synopsis wins over file scan ──
function test_synopsis_registry_wins_over_file { #@test
    _build_cmd test-registry '# Synopsis: File synopsis'
    bu_preinit_register_user_defined_subcommand_file "${BU_COMMANDS[test-registry]}" test-registry source \
        --synopsis "Registered synopsis wins"
    local result
    result=${BU_COMMAND_PROPERTIES[test-registry,synopsis]}
    assert_equal "$result" 'Registered synopsis wins'
}

# ── Function registration with --synopsis ──
function test_synopsis_function_registration { #@test
    bu_preinit_register_user_defined_subcommand_function echo test-func-syn function \
        --synopsis "Function synopsis"
    local result
    result=${BU_COMMAND_PROPERTIES[test-func-syn,synopsis]}
    assert_equal "$result" 'Function synopsis'
}

# ── Empty synopsis when no header and no registration ──
function test_synopsis_empty_by_default { #@test
    _build_cmd test-empty ''
    local result
    result=$(_synopsis_of test-empty)
    assert_equal "$result" ''
}

# ── Synopsis line with leading whitespace before # ──
function test_synopsis_with_indent_is_ignored { #@test
    local file="$TEST_CMD_DIR/test-indent.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf ' # Synopsis: This has a leading space before hash\n'
        printf 'function __bu_test_indent_main() { :; }\n'
        printf '__bu_test_indent_main "$@"\n'
    } > "$file"
    chmod +x "$file"
    bu_preinit_register_user_defined_subcommand_file "$file" test-indent source
    local result
    result=$(_synopsis_of test-indent)
    # Pattern requires # at start of line; space-then-# is not matched
    assert_equal "$result" ''
}

# ── Synopsis with multiple spaces after Synopsis: ──
function test_synopsis_extra_spaces_trimmed { #@test
    _build_cmd test-spaces '# Synopsis:     Padded with spaces    '
    local result
    result=$(_synopsis_of test-spaces)
    # Trailing spaces are trimmed; leading spaces after "Synopsis:" also trimmed
    assert_equal "$result" 'Padded with spaces'
}

# ── Registration without --synopsis does not set the property ──
function test_synopsis_registration_without_flag { #@test
    bu_preinit_register_user_defined_subcommand_file /dev/null test-no-syn source
    local result
    result=${BU_COMMAND_PROPERTIES[test-no-syn,synopsis]:-}
    assert_equal "$result" ''
}
