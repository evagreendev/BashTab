#!/usr/bin/env -S bats --jobs 16

# ===========================================================================
# Tests for generic CLI rename (BU_USER_DEFINED_CLI_COMMAND_NAME) support.
# These must run in a dedicated file because BU_CLI_COMMAND_NAME is set
# once at init time, before the guarded variable block.
# ===========================================================================

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"

    # Set the CLI name BEFORE sourcing so bu_core_var.sh picks it up
    export BU_USER_DEFINED_CLI_COMMAND_NAME=xx
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"
}

function test_cli_rename_help_uses_cli_name { #@test
    # Bug 1: help text should reference the actual CLI name, not hardcoded "bu"
    run __bu_cli_help
    assert_success

    # The old hardcoded "bu" prose patterns must NOT appear
    refute_output --partial 'bu is a Verb-Noun CLI'
    refute_output --partial 'Type bu <TAB>'
    refute_output --partial 'Run bu <command>'

    # Strip ANSI escapes to check plain text for "xx" (renamed CLI)
    local plain
    plain=$(printf '%s' "$output" | sed 's/'$'\e''\[[0-9;]*[a-zA-Z]//g' | sed 's/'$'\e''[()].//g')
    [[ "$plain" == *'Help for xx'* ]]
    [[ "$plain" == *'xx is a Verb-Noun CLI'* ]]
    [[ "$plain" == *'xx get-command | xx where-object'* ]]
}

function test_cli_rename_pipeline_field_completion { #@test
    # Bug 2: pipeline field completion should resolve producer fields
    # when the CLI is renamed. The registries are keyed on "bu <cmd>",
    # so "xx get-command" must be canonicalized to "bu get-command".
    local command_line_front_before_pipe="xx get-command"
    __bu_out_complete_pipeline_fields ""
    assert_equal "${BU_RET[*]}" "name verb noun namespace type"
}

function test_cli_rename_alias_completion { #@test
    # Bug 3: BU_CLI_COMMAND_ALIASES allows additional names to be
    # accepted by the completion function guard.
    BU_CLI_COMMAND_ALIASES+=(j)

    # Completion invoked with alias "j" should NOT bail at the guard
    COMPREPLY=()
    COMP_CWORD=1
    COMP_WORDS=(j "")
    COMP_LINE="j "
    COMP_POINT=2
    __bu_autocomplete_completion_func_cli j "" ""
    # Should have completions (all registered commands)
    assert [ "${#COMPREPLY[@]}" -gt 0 ]
}
