#!/usr/bin/env -S bats --jobs 16

# Command-line transforms (lib/core/bu_core_transform.sh): match->replace
# engine, validity checker, auto-inverse derivation, module provenance, and
# the `bu get-transform` cmdlet.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # shellcheck source=../bu_entrypoint.sh
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"
}

function test_transform_wrap_unwrap_sudo { #@test
    bu_preinit_register_line_transform wrap-sudo --match '{line}' --replace 'sudo {line}' --description 'Wrap in sudo'
    local out
    __bu_transform_apply wrap-sudo 'apt update' out
    assert_equal "$out" 'sudo apt update'

    __bu_transform_apply unwrap-sudo 'sudo apt update' out
    assert_equal "$out" 'apt update'

    # No match: returns non-zero and leaves the line untouched.
    run __bu_transform_apply unwrap-sudo 'apt update' out
    assert_failure
}

function test_transform_wrap_gdb_roundtrip_is_exact { #@test
    bu_preinit_register_line_transform wrap-gdb --match '{line}' --replace 'gdb {prog} --args {line}'
    local out out2
    __bu_transform_apply wrap-gdb 'apt   update' out
    assert_equal "$out" 'gdb apt --args apt   update'

    __bu_transform_apply unwrap-gdb "$out" out2
    assert_equal "$out2" 'apt   update'
}

function test_transform_token_mode_args { #@test
    bu_preinit_register_line_transform drop-log --match 'LOG=INFO {args}' --replace '{args}'
    local out
    __bu_transform_apply drop-log 'LOG=INFO run foo' out
    assert_equal "$out" 'run foo'
}

function test_transform_auto_inverse_naming { #@test
    bu_preinit_register_line_transform wrap-timeout --match '{line}' --replace 'timeout 30s {line}'
    bu_preinit_register_line_transform foo --match '{line}' --replace 'FOO {line}'

    assert_equal "${BU_LINE_TRANSFORM_PROPERTIES[wrap-timeout,derived]}" false
    assert_equal "${BU_LINE_TRANSFORM_PROPERTIES[unwrap-timeout,derived]}" true
    assert_equal "${BU_LINE_TRANSFORM_PROPERTIES[foo,derived]}" false
    assert_equal "${BU_LINE_TRANSFORM_PROPERTIES[foo-inverse,derived]}" true
}

function test_transform_forward_only_when_swap_invalid { #@test
    # {line} -> sudo {prog} drops the args, so the swapped rule cannot recover
    # {line} from its match; the forward registers but no inverse is derived.
    bu_preinit_register_line_transform forward-only --match '{line}' --replace 'sudo {prog}'
    assert_equal "${BU_LINE_TRANSFORM_PROPERTIES[forward-only,replace]}" 'sudo {prog}'
    assert_equal "${BU_LINE_TRANSFORM_PROPERTIES[forward-only-inverse,match]:-}" ''
}

function test_transform_validation_rejects_bad_rules { #@test
    run bu_preinit_register_line_transform bad --match '{lnie}' --replace 'x {line}'
    assert_failure

    run bu_preinit_register_line_transform bad --match "bash -c '{line}'" --replace '{line}'
    assert_failure

    run bu_preinit_register_line_transform bad --match '{line} {line}' --replace '{line}'
    assert_failure

    run bu_preinit_register_line_transform bad --match '{line} {args}' --replace '{line}'
    assert_failure

    run bu_preinit_register_line_transform bad --match '{args} {prog}' --replace '{line}'
    assert_failure

    run bu_preinit_register_line_transform bad --match '{args}' --replace '{line}'
    assert_failure
}

function test_transform_module_provenance { #@test
    local preinit="$BATS_TEST_TMPDIR/moda-preinit.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'source "$BU_NULL"'
        echo "bu_preinit_register_line_transform wrap-sudo --match '{line}' --replace 'sudo {line}' --description 'Wrap in sudo'"
    } > "$preinit"

    run bash -c '
        export BU_TOP_LEVEL_MODULE=moda
        export BU_MODULE_LIST="moda:0.1.0:$1;"
        source "$2"/bu_entrypoint.sh >/dev/null 2>&1
        echo "MODULE=$(bu get-transform --format jsonl 2>/dev/null | jq -r "select(.name == \"wrap-sudo\") | .module")"
        echo "INVERSE_MODULE=$(bu get-transform --format jsonl 2>/dev/null | jq -r "select(.name == \"unwrap-sudo\") | .module")"
    ' _ "$preinit" "$DIR"/..
    assert_success
    assert_line "MODULE=moda"
    assert_line "INVERSE_MODULE=moda"
}

function test_get_transform_cmdlet { #@test
    bu_preinit_register_line_transform wrap-sudo --match '{line}' --replace 'sudo {line}' --description 'Wrap in sudo'

    run bu get-transform --format jsonl
    assert_success

    local row
    row=$(bu get-transform --format jsonl | jq -r 'select(.name == "wrap-sudo") | [.module,.derived] | @tsv')
    assert_equal "$row" $'bu\tfalse'

    row=$(bu get-transform --format jsonl | jq -r 'select(.name == "unwrap-sudo") | [.module,.derived] | @tsv')
    assert_equal "$row" $'bu\ttrue'
}
