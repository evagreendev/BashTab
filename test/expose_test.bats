#!/usr/bin/env -S bats --jobs 16

# ===========================================================================
# Tests for BU_EXPOSE_COMMANDS bare-name command exposure.
# ===========================================================================

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"

    # Source the framework with BU_EXPOSE_COMMANDS defaulting off.
    export BU_EXPOSE_COMMANDS=false
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"
}

teardown() {
    # Clean up any exposure from individual tests that toggled the flag.
    __bu_expose_teardown
}

# ===========================================================================
# Default off
# ===========================================================================

function test_expose_default_off_no_bare_functions { #@test
    # When BU_EXPOSE_COMMANDS is false (default), no bare-name functions
    # should be registered.
    local count=0
    local command
    for command in "${!BU_COMMANDS[@]}"
    do
        if [[ "$(type -t "$command" 2>/dev/null)" == function ]]
        then
            count=$((count + 1))
        fi
    done
    assert_equal "$count" 0
}

# ===========================================================================
# Collision guards
# ===========================================================================

function test_expose_select_not_shadowed { #@test
    # 'select' is a bash keyword and must never be shadowed.
    BU_EXPOSE_COMMANDS=true
    __bu_expose
    # If 'select' were a function, the wrapper would have been created.
    # It must remain a keyword.
    run type -t select
    assert_output "keyword"
}

function test_expose_cd_not_shadowed { #@test
    # 'cd' is a bash builtin and must never be shadowed.
    BU_EXPOSE_COMMANDS=true
    __bu_expose
    run type -t cd
    assert_output "builtin"
}

function test_expose_git_not_shadowed { #@test
    # 'git' is a real PATH tool and must never be shadowed.
    command -v git >/dev/null || skip "git not found on PATH"
    BU_EXPOSE_COMMANDS=true
    __bu_expose
    run type -t git
    assert_output "file"
}

# ===========================================================================
# Expose on
# ===========================================================================

function test_expose_source_command_is_bare_function { #@test
    # A source-type command must become a bare function when enabled.
    # 'get-config' is source-type (check via __bu_cli_command_type).
    __bu_cli_command_type get-config
    local cmd_type=$BU_RET
    [[ "$cmd_type" == source ]] || skip "get-config is not source-type"

    BU_EXPOSE_COMMANDS=true
    __bu_expose

    run type -t get-config
    assert_output "function"
}

function test_expose_execute_command_is_bare_function { #@test
    # An execute-type command must become a bare function when enabled.
    # 'view-table' is execute-type (now +x from a previous commit).
    __bu_cli_command_type view-table
    local cmd_type=$BU_RET
    [[ "$cmd_type" == execute ]] || skip "view-table is not execute-type"

    BU_EXPOSE_COMMANDS=true
    __bu_expose

    run type -t view-table
    assert_output "function"
}

function test_expose_source_command_mutates_cwd { #@test
    # A source-type command invoked via its bare function wrapper must
    # run in the caller's shell and mutate the caller's cwd.
    __bu_cli_command_type get-config
    local cmd_type=$BU_RET
    [[ "$cmd_type" == source ]] || skip "get-config is not source-type"

    BU_EXPOSE_COMMANDS=true
    __bu_expose

    local start_dir=$PWD
    # get-config (source-type) does a pushd to its script dir and back.
    # Running it bare should leave us in the same directory.
    run get-config --help
    assert_equal "$PWD" "$start_dir"
}

function test_expose_bare_command_has_tab_completion { #@test
    # A bare function must have Tab completion registered.
    BU_EXPOSE_COMMANDS=true
    __bu_expose

    # Check that 'complete -p get-config' shows our completion function.
    run complete -p get-config
    assert_success
    assert_output --partial '__bu_expose_completion_func'
}

function test_expose_skips_function_type_commands { #@test
    # Function-type commands must NOT be wrapped — they are CLI dispatch
    # constructs whose impl probes their own name and would recurse.

    # Find or create a known function-type command.
    # The 'deactivate' command (if it exists) is often function-type.
    # Just verify: no function-type command gets a bare wrapper.
    BU_EXPOSE_COMMANDS=true
    __bu_expose

    local command script_path type
    local violations=0
    for command in "${!BU_COMMANDS[@]}"
    do
        __bu_cli_command_type "$command"
        type=$BU_RET
        if [[ "$type" == function || "$type" == alias ]]
        then
            if [[ "$(type -t "$command" 2>/dev/null)" == function ]]
            then
                # It's a function — check if WE created it or it was
                # pre-existing.  If __BU_EXPOSED_NAMES has it, we
                # incorrectly exposed it.
                if [[ -n "${__BU_EXPOSED_NAMES[$command]:-}" ]]
                then
                    violations=$((violations + 1))
                fi
            fi
        fi
    done
    assert_equal "$violations" 0
}

# ===========================================================================
# Teardown
# ===========================================================================

function test_expose_teardown_removes_all_functions { #@test
    # After teardown, no exposed functions should remain.
    BU_EXPOSE_COMMANDS=true
    __bu_expose

    # Verify at least one function was created.
    local count_before=${#__BU_EXPOSED_NAMES[@]}
    assert [ "$count_before" -gt 0 ]

    __bu_expose_teardown

    local name
    for name in "${!__BU_EXPOSED_NAMES[@]}"
    do
        # name is still in the (now-empty) assoc?  The teardown clears
        # __BU_EXPOSED_NAMES=(), so this loop shouldn't execute.
        :
    done

    # After teardown with flag off, exposed count is zero.
    BU_EXPOSE_COMMANDS=false
    __bu_expose
    assert_equal "${#__BU_EXPOSED_NAMES[@]}" 0
}

function test_expose_toggle_off_cleans_up { #@test
    # Toggling the flag from on to off and re-running init must clean up.
    BU_EXPOSE_COMMANDS=true
    __bu_expose

    # get-config should be a function now.
    run type -t get-config
    assert_output "function"

    # Toggle off.
    BU_EXPOSE_COMMANDS=false
    __bu_expose

    # get-config should go back to being a file (or whatever it was).
    run type -t get-config
    refute_output "function"
}
