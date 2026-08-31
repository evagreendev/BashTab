#!/usr/bin/env -S bats --jobs 16

# ===========================================================================
# API contract tests — lock the parse/driver behaviors that external
# projects embedding BashTab depend on, so upstream refactors can't
# silently break embedders.
# ===========================================================================

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"
}

# ===========================================================================
# bu_parse_positional
# ===========================================================================

function test_parse_positional_increments_shift_by { #@test
    # After bu_parse_positional, shift_by must be incremented by 1
    # and the autocompletion array populated from args after the count.
    local shift_by=1
    local __bu_g_shift_by=0
    local autocompletion=()

    bu_parse_positional 5 --hint "my hint"
    assert_equal "$shift_by" 2
    assert_equal "${autocompletion[*]}" '--hint my hint'
}

function test_parse_positional_noop_when_shift_by_exceeds { #@test
    # When shift_by >= num_args, bu_parse_positional is a no-op:
    # shift_by and autocompletion are left untouched.
    local shift_by=2
    local __bu_g_shift_by=0
    local autocompletion=(--original value)

    bu_parse_positional 2 --hint "should not appear"
    assert_equal "$shift_by" 2
    assert_equal "${autocompletion[*]}" '--original value'
}

# ===========================================================================
# bu_parse_multiselect
# ===========================================================================

function test_parse_multiselect_sets_shift_by_and_autocompletion { #@test
    # bu_parse_multiselect always sets shift_by=1 and populates
    # autocompletion with --options-at referencing the caller's
    # source file and line.
    local shift_by=0
    local __bu_g_shift_by=0
    local autocompletion=()
    local error_msg=

    bu_parse_multiselect 3 --some-flag
    assert_equal "$shift_by" 1
    # autocompletion[0] must be --options-at (or --options-of)
    assert_equal "${autocompletion[0]}" '--options-at'
    # The BASH_SOURCE[1] and BASH_LINENO[0] reference the caller
    assert [ "${#autocompletion[@]}" -ge 3 ]
}

# ===========================================================================
# bu_parse_inject
# ===========================================================================

function test_parse_inject_appends_options_of { #@test
    # bu_parse_inject must append --options-of <impl> to the
    # existing autocompletion array, not replace it.
    local shift_by=1
    local __bu_g_shift_by=0
    local autocompletion=(--original entry)

    __test_inject_resolver() { return 0; }

    bu_parse_inject __test_inject_resolver arg1 arg2
    assert_equal "${autocompletion[0]}" '--original'
    assert_equal "${autocompletion[1]}" 'entry'
    assert_equal "${autocompletion[2]}" '--options-of'
    assert_equal "${autocompletion[3]}" '__test_inject_resolver'

    unset -f __test_inject_resolver
}

function test_parse_inject_returns_impl_status { #@test
    # bu_parse_inject must return the impl's exit code so callers
    # can chain with ||.
    local shift_by=1
    local __bu_g_shift_by=0
    local autocompletion=()

    __test_returns_0() { return 0; }
    __test_returns_1() { return 1; }
    __test_returns_124() { return 124; }

    run bu_parse_inject __test_returns_0
    assert_equal "$status" 0

    run bu_parse_inject __test_returns_1
    assert_equal "$status" 1

    run bu_parse_inject __test_returns_124
    assert_equal "$status" 124

    unset -f __test_returns_0 __test_returns_1 __test_returns_124
}

function test_parse_inject_multiselect_appends_not_replaces { #@test
    # When __bu_g_is_inject is true, bu_parse_multiselect must
    # append to autocompletion instead of resetting it.
    local shift_by=0
    local __bu_g_shift_by=0
    local error_msg=
    local autocompletion=(--preexisting completions)
    local __bu_g_is_inject=true

    bu_parse_multiselect 3 --some-flag
    assert_equal "${autocompletion[0]}" '--preexisting'
    assert_equal "${autocompletion[1]}" 'completions'
    assert_equal "${autocompletion[2]}" '--options-at'
}

function test_parse_inject_positional_appends_not_replaces { #@test
    # When __bu_g_is_inject is true, bu_parse_positional must
    # append to autocompletion instead of resetting it.
    local shift_by=0
    local __bu_g_shift_by=0
    local autocompletion=(--preexisting completions)
    local __bu_g_is_inject=true

    bu_parse_positional 1 --hint "some hint"
    assert_equal "${autocompletion[0]}" '--preexisting'
    assert_equal "${autocompletion[1]}" 'completions'
    assert_equal "${autocompletion[2]}" '--hint'
    assert_equal "${autocompletion[3]}" 'some hint'
}

function test_parse_inject_compose_two_impls { #@test
    # A catch-all arm calling bu_parse_inject resolver_a ||
    # bu_parse_inject resolver_b must offer both resolvers'
    # options in the autocompletion array.
    local shift_by=1
    local __bu_g_shift_by=0
    local autocompletion=()

    __test_resolver_a() {
        local error_msg=
        bu_parse_multiselect 3 --flag-a
        return 1
    }
    __test_resolver_b() {
        local error_msg=
        bu_parse_positional 1 --hint "resolver b hint"
        return 0
    }

    bu_parse_inject __test_resolver_a arg || bu_parse_inject __test_resolver_b arg

    # Should contain both --options-of entries and both resolvers' contributions
    assert [ "${#autocompletion[@]}" -ge 4 ]

    unset -f __test_resolver_a __test_resolver_b
}

function test_parse_without_inject_resets_normally { #@test
    # Regression: without the inject flag, bu_parse_positional and
    # bu_parse_multiselect must reset autocompletion exactly as
    # before (byte-identical behavior when __bu_g_is_inject is unset).
    local shift_by=0
    local __bu_g_shift_by=0
    local error_msg=
    local autocompletion=(--old)

    bu_parse_multiselect 3 --some-flag
    assert_equal "${autocompletion[0]}" '--options-at'
    assert [ "${#autocompletion[@]}" -ge 3 ]

    shift_by=0
    autocompletion=(--old)
    bu_parse_positional 1 --hint "hint"
    assert_equal "${autocompletion[0]}" '--hint'
    assert_equal "${autocompletion[1]}" 'hint'
}

# ===========================================================================
# bu_parse_nested_multiselect
# ===========================================================================

function test_parse_nested_multiselect_publishes_options_and_shift { #@test
    # Like bu_parse_nested but for a repeatable subcommand: autocompletion
    # is replaced with --options-of <impl>, the impl is dispatched with the
    # first following word, and the cursor advances past the current word
    # plus the impl's first word (saved_shift_by + 1).
    local shift_by=1
    local __bu_g_shift_by=0
    local autocompletion=(--old)
    local error_msg=
    local is_help=false
    local seen=
    declare -A bu_parsed_multiselect_arguments=()

    __test_nms_opts() {
        seen=$1
        case "$1" in
        a|b|c) ;;
        *) bu_parse_error_enum "$1" ;;
        esac
    }

    bu_parse_nested_multiselect __test_nms_opts sub a b

    assert_equal "${autocompletion[0]}" '--options-of'
    assert_equal "${autocompletion[1]}" '__test_nms_opts'
    assert_equal "$seen" 'a'
    assert_equal "$shift_by" 2

    unset -f __test_nms_opts
}

function test_parse_nested_multiselect_records_only_in_autocomplete { #@test
    # The just-consumed word must be recorded in the multiselect dedup map
    # only while completing, exactly like bu_parse_multiselect does.
    local shift_by=1
    local __bu_g_shift_by=0
    local autocompletion=()
    local error_msg=
    local is_help=false
    declare -A bu_parsed_multiselect_arguments=()

    __test_nms_opts() {
        case "$1" in
        a|b|c) ;;
        *) bu_parse_error_enum "$1" ;;
        esac
    }

    # No autocomplete context → no dedup entry.
    local COMP_CWORD=
    local BU_COMP_FAKE=
    shift_by=1
    bu_parse_nested_multiselect __test_nms_opts sub a b
    assert_equal "${bu_parsed_multiselect_arguments[sub]:-}" ''

    # Autocomplete context → the consumed word is recorded.
    COMP_CWORD=1
    bu_parsed_multiselect_arguments=()
    shift_by=1
    bu_parse_nested_multiselect __test_nms_opts sub a b
    assert_equal "${bu_parsed_multiselect_arguments[sub]:-}" '1'

    unset -f __test_nms_opts
}

function test_parse_nested_multiselect_stay_shift_and_options { #@test
    # The stay variant is like bu_parse_nested_multiselect but leaves
    # shift_by=1 so the outer loop stays in multiselect position.
    local shift_by=1
    local __bu_g_shift_by=0
    local autocompletion=(--old)
    local error_msg=
    local is_help=false
    local seen=
    declare -A bu_parsed_multiselect_arguments=()

    __test_nms_stay_opts() {
        seen=$1
        case "$1" in
        a|b|c) ;;
        *) bu_parse_error_enum "$1" ;;
        esac
    }

    bu_parse_nested_multiselect_stay __test_nms_stay_opts sub a b

    assert_equal "${autocompletion[0]}" '--options-of'
    assert_equal "${autocompletion[1]}" '__test_nms_stay_opts'
    assert_equal "$seen" 'a'
    assert_equal "$shift_by" 1

    unset -f __test_nms_stay_opts
}

function test_parse_nested_multiselect_repeatable_subcommand_end_to_end { #@test
    # A command with a repeatable subcommand offers the nested impl's options
    # at the subcommand position and filters already-used ones out.
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/test-nms-cmd.sh" <<'EOF'
#!/usr/bin/env bash
# Dispatch: source
function __bu_test_nms_cmd_main()
{
source "$BU_NULL"
bu_scope_push_function
bu_run_log_command "$@"
local shift_by=
local __bu_g_shift_by=0
local is_help=false
local error_msg=
local autocompletion=()
local sub_active=false

function __test_nms_opts()
{
    case "$1" in
    a|b|c) ;;
    *) bu_parse_error_enum "$1" ;;
    esac
}

while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    sub)
        sub_active=true
        bu_parse_nested_multiselect __test_nms_opts "$@"
        ;;
    *)
        if "$sub_active"
        then
            bu_parse_nested_multiselect __test_nms_opts "$@"
        else
            bu_parse_error_enum "$1"
            break
        fi
        ;;
    esac
    if "$is_help"; then break; fi
    if (( $# < shift_by )); then bu_parse_error_argn "$1" $#; break; fi
    shift "$shift_by"
done
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi
if "$is_help"
then
    echo "error: $error_msg"
else
    echo consumed
fi
bu_scope_pop_function
}
__bu_test_nms_cmd_main "$@"
EOF
    chmod +x "$tmpdir/test-nms-cmd.sh"
    bu_preinit_register_user_defined_subcommand_file "$tmpdir/test-nms-cmd.sh" test-nms-cmd source

    # Subcommand position: all impl options offered.
    COMPREPLY=()
    BU_COMPREPLY_METADATA=()
    bu_autocomplete_get_autocompletions bu test-nms-cmd sub ""
    assert_equal "${COMPREPLY[*]}" 'a b c'

    # Non-autocomplete execution dispatches to the impl and validates.
    run bu test-nms-cmd sub a b
    assert_success
    assert_output 'consumed'

    run bu test-nms-cmd sub x
    assert_output --partial 'Unrecognized option[x]'

    rm -rf "$tmpdir"
}

function test_parse_nested_multiselect_stay_repeatable_subcommand_end_to_end { #@test
    # The stay variant keeps the outer loop in multiselect position, so each
    # used option is filtered out of subsequent completions.
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/test-nms-stay.sh" <<'EOF'
#!/usr/bin/env bash
# Dispatch: source
function __bu_test_nms_stay_main()
{
source "$BU_NULL"
bu_scope_push_function
bu_run_log_command "$@"
local shift_by=
local __bu_g_shift_by=0
local is_help=false
local error_msg=
local autocompletion=()
local sub_active=false

function __test_nms_stay_opts()
{
    case "$1" in
    a|b|c) ;;
    *) bu_parse_error_enum "$1" ;;
    esac
}

while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    sub)
        sub_active=true
        bu_parse_nested_multiselect_stay __test_nms_stay_opts "$@"
        ;;
    *)
        if "$sub_active"
        then
            bu_parse_nested_multiselect_stay __test_nms_stay_opts "$@"
        else
            bu_parse_error_enum "$1"
            break
        fi
        ;;
    esac
    if "$is_help"; then break; fi
    if (( $# < shift_by )); then bu_parse_error_argn "$1" $#; break; fi
    shift "$shift_by"
done
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi
if "$is_help"
then
    echo "error: $error_msg"
else
    echo consumed
fi
bu_scope_pop_function
}
__bu_test_nms_stay_main "$@"
EOF
    chmod +x "$tmpdir/test-nms-stay.sh"
    bu_preinit_register_user_defined_subcommand_file "$tmpdir/test-nms-stay.sh" test-nms-stay source

    # Subcommand position: all impl options offered.
    COMPREPLY=()
    BU_COMPREPLY_METADATA=()
    bu_autocomplete_get_autocompletions bu test-nms-stay sub ""
    assert_equal "${COMPREPLY[*]}" 'a b c'

    # After `sub a`, `a` is filtered out.
    COMPREPLY=()
    BU_COMPREPLY_METADATA=()
    bu_autocomplete_get_autocompletions bu test-nms-stay sub a ""
    assert_equal "${COMPREPLY[*]}" 'b c'

    # After `sub a b`, both are filtered out.
    COMPREPLY=()
    BU_COMPREPLY_METADATA=()
    bu_autocomplete_get_autocompletions bu test-nms-stay sub a b ""
    assert_equal "${COMPREPLY[*]}" 'c'

    # Non-autocomplete execution validates each option.
    run bu test-nms-stay sub a b
    assert_success
    assert_output 'consumed'

    run bu test-nms-stay sub a x
    assert_output --partial 'Unrecognized option[x]'

    rm -rf "$tmpdir"
}

# ===========================================================================
# bu_autocomplete
# ===========================================================================

function test_autocomplete_copies_array_to_bu_ret_and_pops_scope { #@test
    # bu_autocomplete copies the autocompletion array into BU_RET
    # and, by default, pops a function-level scope.
    local autocompletion=(--hint name --enum a b c enum--)
    local BU_RET=()

    bu_scope_push_function
    bu_autocomplete
    # BU_RET must contain a copy of autocompletion
    assert_equal "${BU_RET[*]}" "${autocompletion[*]}"
    # The function scope pushed above has been popped
    assert_equal "${#BU_SCOPE_STACK[@]}" 0
}

function test_autocomplete_no_pop_flag { #@test
    # With --no-pop, bu_autocomplete copies the array but leaves
    # the scope stack alone.
    local autocompletion=(--hint x)
    local BU_RET=()

    bu_scope_push_function
    bu_autocomplete --no-pop
    assert_equal "${BU_RET[*]}" '--hint x'
    # Scope must still be present
    assert [ "${#BU_SCOPE_STACK[@]}" -gt 0 ]
    # Clean up
    bu_scope_pop_function
}

# ===========================================================================
# Literal DSL (:value)
# ===========================================================================

function test_literal_dsl_in_master_helper { #@test
    # The master helper treats `:token` as an explicit literal
    # completion. Passing `:hello :world` must produce
    # COMPREPLY=(hello world).
    local COMPREPLY=()
    local BU_COMPREPLY_METADATA=()
    declare -A bu_parsed_multiselect_arguments=()

    __bu_autocomplete_completion_func_master_helper \
        __test_literal_dsl "" "" :hello :world

    assert_equal "${COMPREPLY[*]}" 'hello world'
}

# ===========================================================================
# BU_USER_DEFINED_AUTOCOMPLETE_HELPERS
# ===========================================================================

function test_user_defined_autocomplete_helper { #@test
    # A helper registered in BU_USER_DEFINED_AUTOCOMPLETE_HELPERS
    # is invoked by the master helper. Its COMPREPLY additions must
    # survive and its BU_RET arg-consumption count must be honored.
    local -a saved_helpers=("${BU_USER_DEFINED_AUTOCOMPLETE_HELPERS[@]}")

    __test_my_helper() {
        # Consume the first DSL arg as our "custom verb" token
        COMPREPLY+=(custom-result)
        BU_RET=1  # consumed 1 arg
        return 0
    }
    BU_USER_DEFINED_AUTOCOMPLETE_HELPERS=(__test_my_helper)

    local COMPREPLY=()
    local BU_COMPREPLY_METADATA=()
    declare -A bu_parsed_multiselect_arguments=()

    __bu_autocomplete_completion_func_master_helper \
        __test_custom_target "" "" __test_custom_verb extra-arg

    # The helper should have fired and added to COMPREPLY
    assert [ "${#COMPREPLY[@]}" -gt 0 ]
    assert_equal "${COMPREPLY[0]}" 'custom-result'

    # Restore helpers
    BU_USER_DEFINED_AUTOCOMPLETE_HELPERS=("${saved_helpers[@]}")
    unset -f __test_my_helper
}

function test_user_defined_autocomplete_lazy_set_e_safe { #@test
    # A helper legitimately returning 1 ("not my verb") must not abort
    # the loop caller under `set -e`.  The second helper must still run.
    local -a saved_helpers=("${BU_USER_DEFINED_AUTOCOMPLETE_HELPERS[@]}")

    __test_reject_helper() {
        # "Not my verb" — designed to return 1
        (($#)) && [[ "$1" == test-verb ]] && return 1 || return 1
    }
    __test_accept_helper() {
        COMPREPLY+=(accepted-by-second)
        BU_RET=0
        return 0
    }

    BU_USER_DEFINED_AUTOCOMPLETE_HELPERS=(__test_reject_helper __test_accept_helper)

    local COMPREPLY=() BU_RET=0

    # Run under set -e; if the first helper's non-zero return aborts,
    # the second helper never fires and COMPREPLY stays empty.
    set -e
    bu_user_defined_autocomplete_lazy test-verb extra
    set +e

    assert_equal "${COMPREPLY[0]:-}" 'accepted-by-second'

    BU_USER_DEFINED_AUTOCOMPLETE_HELPERS=("${saved_helpers[@]}")
    unset -f __test_reject_helper __test_accept_helper
}

# ===========================================================================
# bu_env_is_in_autocomplete
# ===========================================================================

function test_env_is_in_autocomplete_true_with_comp_cword { #@test
    # bu_env_is_in_autocomplete is true when COMP_CWORD is non-empty
    # and BU_COMP_FAKE is unset.
    local COMP_CWORD=1
    local BU_COMP_FAKE=
    run bu_env_is_in_autocomplete
    assert_success

    # Unset COMP_CWORD → false
    local COMP_CWORD=
    run bu_env_is_in_autocomplete
    assert_failure
}

function test_env_is_in_autocomplete_false_with_bu_comp_fake { #@test
    # BU_COMP_FAKE suppresses autocomplete mode even when
    # COMP_CWORD is non-empty.
    local COMP_CWORD=1
    local BU_COMP_FAKE=true
    run bu_env_is_in_autocomplete
    assert_failure
}

# ===========================================================================
# Scope cleanup: push → add_cleanup → pop_function
# ===========================================================================

function test_scope_cleanup_runs_exactly_once { #@test
    # bu_scope_push_function + bu_scope_add_cleanup + bu_scope_pop_function
    # must run the registered cleanup exactly once.
    local marker_file
    marker_file=$(mktemp)

    bu_scope_push_function
    bu_scope_add_cleanup rm -f "$marker_file"

    # Before pop, the file should exist (we just created it)
    assert [ -f "$marker_file" ]

    bu_scope_pop_function

    # After pop, the cleanup must have run and removed the file
    assert [ ! -f "$marker_file" ]
}

function test_scope_cleanup_arg_with_space { #@test
    # A cleanup argument containing a space must survive the round trip
    # through printf '%q ' (store) and eval (execute) as one argument.
    local d
    d=$(mktemp -d)
    bu_scope_push_function
    bu_scope_add_cleanup touch "$d/a b.done"
    bu_scope_pop_function
    assert [ -f "$d/a b.done" ]
    rm -rf "$d"
}

function test_scope_cleanup_arg_with_metachar { #@test
    # Shell metacharacters in a cleanup argument must be stored as
    # literals, not interpreted by eval at execution time.
    local d
    d=$(mktemp -d)
    bu_scope_push_function
    # $ is a shell metachar; %q escapes it so eval treats it literally
    bu_scope_add_cleanup touch "$d/dollar\$.done"
    bu_scope_pop_function
    assert [ -f "$d/dollar\$.done" ]
    rm -rf "$d"
}

function test_scope_cleanup_multiple_args_preserved { #@test
    # Simple multi-word cleanups (function name + args) still dispatch
    # correctly through eval.
    local d
    d=$(mktemp -d)
    bu_scope_push_function
    bu_scope_add_cleanup rm -rf "$d"
    bu_scope_pop_function
    assert [ ! -d "$d" ]
}

# ===========================================================================
# bu_cached_execute
# ===========================================================================

function test_cached_execute_output_on_stdout { #@test
    # bu_cached_execute writes command output to stdout, not BU_RET.
    local result
    result=$(bu_cached_execute --allow-empty -- echo hello-contract 2>/dev/null)
    assert_equal "$result" 'hello-contract'
}

function test_cached_execute_dir_option { #@test
    # --dir overrides the cache directory.
    local tmpcache
    tmpcache=$(mktemp -d)

    run bu_cached_execute --dir "$tmpcache" --allow-empty -- echo ok 2>/dev/null
    assert_success
    # A cache file should have been created in our custom dir
    assert [ "$(find "$tmpcache" -type f | wc -l)" -gt 0 ]

    rm -rf "$tmpcache"
}

function test_cached_execute_allow_empty { #@test
    # --allow-empty prevents empty output from being treated as an error.
    # Without it, an empty-output command returns non-zero.
    run bu_cached_execute --allow-empty -- printf '' 2>/dev/null
    assert_success
}
