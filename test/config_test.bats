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

function test_set_config_layer_natural_fallback { #@test
    local layer_file="$BATS_TEST_TMPDIR/proj.sh"

    # Register a layer resolver that always returns our test file
    bu_config_register_layer proj _proj_resolver
    function _proj_resolver() { echo "$layer_file"; }

    # Register a setting whose natural layer is "proj"
    bu_config_register BU_TEST_LAYERED --default debug \
        --enum debug:0 info:1 enum-- --layer proj

    # Bare write (no --file, no --layer) should land in the natural layer's file
    bu set-config BU_TEST_LAYERED info >/dev/null

    assert grep -q "^BU_TEST_LAYERED=" "$layer_file"
    assert_equal "$(grep "^BU_TEST_LAYERED=" "$layer_file")" "BU_TEST_LAYERED=1"
}

function test_set_config_layer_cross_layer_warns { #@test
    local layer_file="$BATS_TEST_TMPDIR/proj.sh"

    bu_config_register_layer proj _proj_resolver2
    function _proj_resolver2() { echo "$layer_file"; }

    bu_config_register BU_TEST_LAYERED2 --default debug \
        --enum debug:0 info:1 enum-- --layer proj

    # Explicit --layer local on a proj-natural setting should warn
    run bu set-config --layer local BU_TEST_LAYERED2 info
    assert_success
    assert_output --partial "natural layer is 'proj'"

    # It should still write to the local file
    assert grep -q "^BU_TEST_LAYERED2=" "$BU_CONFIG_LOCAL_FILE"
}

function test_set_config_layer_unknown_errors { #@test
    run bu set-config --layer nosuchlayer BU_LOG_LVL info
    assert_failure
    assert_output --partial "Unknown config layer"
    assert_output --partial "local"
}

function test_set_config_layer_file_beats_layer { #@test
    local explicit_file="$BATS_TEST_TMPDIR/explicit.sh"

    bu_config_register_layer proj _proj_resolver3
    function _proj_resolver3() { echo "$BATS_TEST_TMPDIR/proj3.sh"; }

    # Both --file and --layer: --file wins with a warning
    run bu set-config --file "$explicit_file" --layer proj BU_LOG_LVL info
    assert_success
    assert_output --partial "--file takes precedence"

    # Written to the explicit file, not the layer-resolved file
    assert grep -q "^BU_LOG_LVL=" "$explicit_file"
}

function test_config_layer_file_resolver { #@test
    local layer_file="$BATS_TEST_TMPDIR/dynamic.sh"

    bu_config_register_layer dyn _dyn_resolver
    function _dyn_resolver() { echo "$layer_file"; }

    bu_config_layer_file dyn
    assert_equal "$BU_RET" "$layer_file"

    # "local" is built-in
    bu_config_layer_file local
    assert_equal "$BU_RET" "$BU_CONFIG_LOCAL_FILE"

    # Empty also resolves to local
    bu_config_layer_file ""
    assert_equal "$BU_RET" "$BU_CONFIG_LOCAL_FILE"
}

function test_config_completion_layers { #@test
    __bu_config_completion_layers
    # "local" is always present
    [[ " ${BU_RET[*]} " == *" local "* ]] || [[ " ${BU_RET[*]} " == local ]]

    bu_config_register_layer mylayer _fake
    __bu_config_completion_layers
    [[ " ${BU_RET[*]} " == *" mylayer "* ]]
}

function test_config_complete_values_fn_takes_priority { #@test
    # Create some demo directories
    mkdir -p "$BATS_TEST_TMPDIR/demo-a" "$BATS_TEST_TMPDIR/demo-b" "$BATS_TEST_TMPDIR/demo-c"

    function _list_demo_dirs() {
        BU_RET=()
        local d
        for d in "$BATS_TEST_TMPDIR"/demo-*
        do
            [[ -d "$d" ]] && BU_RET+=("$(basename "$d")")
        done
    }

    bu_config_register BU_DEMO_DIR --complete-values _list_demo_dirs
    __bu_config_completion_values BU_DEMO_DIR
    assert_equal "${BU_RET[*]}" "demo-a demo-b demo-c"
}

function test_config_complete_values_fn_prefers_over_enum { #@test
    function _my_dynamic_vals() {
        BU_RET=(alpha beta gamma)
    }

    # Setting has BOTH --enum and --complete-values; function wins
    bu_config_register BU_HYBRID --enum static:x enum-- --complete-values _my_dynamic_vals
    __bu_config_completion_values BU_HYBRID
    assert_equal "${BU_RET[*]}" "alpha beta gamma"
}

function test_config_complete_values_missing_fn_silent { #@test
    # complete_values_fn names a function that does NOT exist
    bu_config_register BU_ORPHAN --complete-values _no_such_function
    __bu_config_completion_values BU_ORPHAN
    # Should be silently empty, no error
    assert_equal "${BU_RET[*]}" ""
}

# ===========================================================================
# Module provenance
# ===========================================================================

function test_config_module_provenance { #@test
    local preinit="$BATS_TEST_TMPDIR/widgets-preinit.sh"
    cat > "$preinit" <<EOF
source "\$BU_NULL"
case " \${BU_CONFIG_NAME_PREFIXES[*]-} " in
*" WIDGET_ "*) ;;
*) BU_CONFIG_NAME_PREFIXES+=(WIDGET_) ;;
esac
bu_config_register WIDGET_COLOR --default blue --hint "widget color"
EOF

    run bash -c '
        export BU_TOP_LEVEL_MODULE=widgetsuite
        export BU_MODULE_LIST="widgetsuite:0.1.0:$1;"
        source "$2"/bu_entrypoint.sh >/dev/null 2>&1
        bu get-config --format jsonl
    ' _ "$preinit" "$DIR"/..
    assert_success

    # A setting registered from a module preinit is stamped with its module.
    assert_equal "$(printf '%s\n' "$output" | jq -r 'select(.name == "WIDGET_COLOR") | .module')" "widgetsuite"

    # Core settings (registered from bu_entrypoint.sh) are stamped as module "bu".
    assert_equal "$(printf '%s\n' "$output" | jq -r 'select(.name == "BU_LOG_LVL") | .module')" "bu"
}

function test_config_module_stamp_sticky { #@test
    # Core settings are stamped "bu" after activation.
    assert_equal "${BU_CONFIG_PROPERTIES[BU_LOG_LVL,module]}" "bu"

    # Unsetting a default-less setting re-sources config/bu_config_dynamic.sh
    # outside the entrypoint (BU_CURRENT_MODULE empty). The sticky stamp must
    # not blank core provenance on that path.
    bu_config_register BU_TEST_NODEFAULT --hint "no default"
    bu set-config BU_TEST_NODEFAULT hello >/dev/null
    bu set-config --unset BU_TEST_NODEFAULT >/dev/null

    assert_equal "${BU_CONFIG_PROPERTIES[BU_LOG_LVL,module]}" "bu"
}
