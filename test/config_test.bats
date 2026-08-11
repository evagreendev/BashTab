#!/usr/bin/env -S bats --jobs 16

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    # get the containing directory of this file
    # use $BATS_TEST_FILENAME instead of ${BASH_SOURCE[0]} or $0,
    # as those will point to the bats executable's location or the preprocessed file respectively
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # shellcheck source=../bu_entrypoint.sh
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"

    # Isolate the local settings file from the real repo config
    BU_CONFIG_LOCAL_FILE="$BATS_TEST_TMPDIR/bu_config_local.sh"
    rm -f "$BU_CONFIG_LOCAL_FILE"
}

function test_config_register_and_validate { #@test
    bu_config_register BU_TEST_WIDGET --default 3 --enum one:1 two:2 three:3 enum-- --hint "test widget"
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_WIDGET,registered]}" true
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_WIDGET,default]}" 3
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_WIDGET,hint]}" "test widget"

    # name:mapped enum accepts the name, stores the mapped value
    bu_config_validate_value BU_TEST_WIDGET two
    assert_equal "$BU_RET" 2

    # unknown value rejected
    run bu_config_validate_value BU_TEST_WIDGET four
    assert_failure
}

function test_config_register_bool { #@test
    bu_config_register BU_TEST_FLAG --bool --default false
    bu_config_validate_value BU_TEST_FLAG true
    assert_equal "$BU_RET" true
    run bu_config_validate_value BU_TEST_FLAG yes
    assert_failure
}

function test_config_register_rejects_bad_name { #@test
    run bu_config_register PATH --bool
    assert_failure
    run bu_config_register BU_lower --bool
    assert_failure
}

function test_set_config_dedupe_last_wins { #@test
    bu set-config BU_LOG_LVL debug >/dev/null
    bu set-config BU_LOG_LVL info >/dev/null
    bu set-config BU_LOG_LVL warn >/dev/null
    # Only one assignment line, holding the last (mapped) value
    local count
    count=$(grep -c "^BU_LOG_LVL=" "$BU_CONFIG_LOCAL_FILE")
    assert_equal "$count" 1
    assert_equal "$(grep "^BU_LOG_LVL=" "$BU_CONFIG_LOCAL_FILE")" "BU_LOG_LVL=3"
    # Immediate effect in the current shell
    assert_equal "$BU_LOG_LVL" 3
}

function test_set_config_unset_restores_registered_default { #@test
    bu set-config BU_LOG_LVL debug >/dev/null
    assert_equal "$BU_LOG_LVL" 1
    bu set-config --unset BU_LOG_LVL >/dev/null
    assert_equal "$BU_LOG_LVL" "$BU_LOG_LVL_WARN"
    [[ "$(grep -c "^BU_LOG_LVL=" "$BU_CONFIG_LOCAL_FILE")" == 0 ]]
}

function test_set_config_rejects_bad_input { #@test
    run bu set-config PATH /foo
    assert_failure
    run bu set-config BU_LOG_LVL bogus
    assert_failure
    run bu set-config BU_BOOTSTRAP_VERBOSE yes
    assert_failure
}

function test_set_config_file_dedupe_last_wins { #@test
    local layer="$BATS_TEST_TMPDIR/layer.sh"

    bu set-config --file "$layer" BU_LOG_LVL debug >/dev/null
    bu set-config --file "$layer" BU_LOG_LVL info >/dev/null

    local count
    count=$(grep -c "^BU_LOG_LVL=" "$layer")
    assert_equal "$count" 1
    assert_equal "$(grep "^BU_LOG_LVL=" "$layer")" "BU_LOG_LVL=2"
}

function test_set_config_file_unset_removes_line { #@test
    local layer="$BATS_TEST_TMPDIR/layer.sh"

    bu set-config --file "$layer" BU_LOG_LVL debug >/dev/null
    assert grep -q "^BU_LOG_LVL=" "$layer"

    bu set-config --file "$layer" --unset BU_LOG_LVL >/dev/null
    ! grep -q "^BU_LOG_LVL=" "$layer"
}

function test_set_config_file_preserves_hand_written_lines { #@test
    local layer="$BATS_TEST_TMPDIR/layer.sh"

    # Write a hand-written assignment before any managed block
    echo 'BU_LOG_LVL=warn' > "$layer"

    # run set-config; capture both stdout and stderr together
    run bu set-config --file "$layer" BU_LOG_LVL info
    assert_success

    # The hand-written line must survive
    assert grep -q "^BU_LOG_LVL=warn$" "$layer"

    # The advisory note must fire (logged via bu_log_warn to stderr, which run captures)
    assert_output --partial "note:"

    # Only one assignment inside the managed block
    local -a managed_lines
    managed_lines=($(sed -n '/>>> bu set-config managed block/,/<<< bu set-config managed block/p' "$layer" | grep -c "^BU_LOG_LVL="))
    assert_equal "$managed_lines" 1

    # unset against the same file must also preserve the hand-written line
    bu set-config --file "$layer" --unset BU_LOG_LVL >/dev/null
    assert grep -q "^BU_LOG_LVL=warn$" "$layer"
}

function test_config_completion_helpers { #@test
    __bu_config_completion_values BU_LOG_LVL
    assert_equal "${BU_RET[*]}" "trace debug info warn err silence"

    bu_config_register BU_TEST_FLAG2 --bool
    __bu_config_completion_values BU_TEST_FLAG2
    assert_equal "${BU_RET[*]}" "true false"

    __bu_config_completion_names
    [[ " ${BU_RET[*]} " == *" BU_LOG_LVL "* ]]
}
