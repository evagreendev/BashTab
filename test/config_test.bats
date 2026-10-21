#!/usr/bin/env -S bats --jobs 16

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    # get the containing directory of this file
    # use $BATS_TEST_FILENAME instead of ${BASH_SOURCE[0]} or $0,
    # as those will point to the bats executable's location or the preprocessed file respectively
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # Isolate the local settings file from the real repo config. Exported
    # before activation: BU_CONFIG_LOCAL_FILE is a static setting, final once
    # activated.
    export BU_CONFIG_LOCAL_FILE="$BATS_TEST_TMPDIR/bu_config_local.sh"
    rm -f "$BU_CONFIG_LOCAL_FILE"

    # shellcheck source=../bu_entrypoint.sh
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"
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

# ===========================================================================
# set-config managed block
# ===========================================================================

function test_set_config_embedder_prefix_roundtrip { #@test
    # Embedders append their own namespaced prefix to BU_CONFIG_NAME_PREFIXES
    # and register settings under it; set/get must round-trip the value.
    BU_CONFIG_NAME_PREFIXES+=(WIDGET_)
    bu_config_register WIDGET_COLOR --default blue --hint "widget color"

    bu set-config WIDGET_COLOR red >/dev/null
    assert_equal "$WIDGET_COLOR" red

    local val
    val=$(bu get-config --format jsonl 2>/dev/null | jq -r 'select(.name == "WIDGET_COLOR") | .value')
    assert_equal "$val" red

    # The value is persisted in the managed block, not just the live shell.
    grep -q '^WIDGET_COLOR=red$' "$BU_CONFIG_LOCAL_FILE"
}

function test_set_config_preserves_outside_lines_byte_for_byte { #@test
    local file="$BATS_TEST_TMPDIR/settings.sh"
    {
        printf '# top comment\n'
        printf 'if [[ -n "$FEATURE_FLAG" ]]; then\n'
        printf '    export HAND_WRITTEN=1\n'
        printf 'fi\n'
        printf '\n'
        printf '# trailing comment with spaces   \n'
    } > "$file"

    local before
    before=$(cat "$file")

    bu set-config --file "$file" BU_TEST_OUTSIDE val >/dev/null 2>&1

    # Everything outside the managed block survives byte-for-byte.
    local actual_before
    actual_before=$(sed '/^# >>> bu set-config managed block/,$d' "$file")
    assert_equal "$actual_before" "$before"

    # And the managed block was appended after it.
    grep -q '^BU_TEST_OUTSIDE=val$' "$file"
}

function test_set_config_rewrites_block_in_place { #@test
    local file="$BATS_TEST_TMPDIR/settings.sh"
    {
        printf '# preamble\n'
        printf 'PRE_EXISTING=keep\n'
    } > "$file"

    bu set-config --file "$file" BU_TEST_AAA first >/dev/null 2>&1
    bu set-config --file "$file" BU_TEST_BBB second >/dev/null 2>&1
    bu set-config --file "$file" BU_TEST_AAA updated >/dev/null 2>&1

    # Exactly one managed block — no duplicates.
    assert_equal "$(grep -c '^# >>> bu set-config managed block' "$file")" 1
    assert_equal "$(grep -c '^# <<< bu set-config managed block' "$file")" 1

    # One sorted NAME=value line per var; the re-set value wins.
    local body
    body=$(sed -n '/^# >>> bu set-config managed block/,/^# <<< bu set-config managed block/p' "$file" | grep '^BU_TEST_')
    assert_equal "$body" $'BU_TEST_AAA=updated\nBU_TEST_BBB=second'

    # Block position stable: the hand-written preamble still precedes it.
    assert_equal "$(sed -n '1p' "$file")" "# preamble"
    assert_equal "$(sed -n '2p' "$file")" "PRE_EXISTING=keep"
    assert_equal "$(sed -n '3p' "$file")" "# >>> bu set-config managed block -- do not hand-edit inside"
}

function test_set_config_after_block_assignment_wins { #@test
    local file="$BATS_TEST_TMPDIR/settings.sh"
    bu set-config --file "$file" BU_TEST_AFTER managed >/dev/null 2>&1

    # Hand-write an assignment AFTER the managed block.
    printf 'BU_TEST_AFTER=handwritten\n' >> "$file"

    # The advisory note names the conflict, but the write still succeeds.
    run bu set-config --file "$file" BU_TEST_AFTER managed2
    assert_success
    assert_output --partial "note: BU_TEST_AFTER"
    assert_output --partial "assigned AFTER the managed block"
    assert_output --partial "overrides the value just set"

    # The managed block value was updated (the note is non-fatal).
    grep -q '^BU_TEST_AFTER=managed2$' "$file"

    # File order is authoritative: the AFTER assignment wins when sourced.
    unset BU_TEST_AFTER
    source "$file"
    assert_equal "$BU_TEST_AFTER" "handwritten"
}

function test_set_config_unset_removes_only_target_pair { #@test
    local file="$BATS_TEST_TMPDIR/settings.sh"
    bu set-config --file "$file" BU_TEST_KEEP1 a >/dev/null 2>&1
    bu set-config --file "$file" BU_TEST_KEEP2 b >/dev/null 2>&1
    bu set-config --file "$file" BU_TEST_DROP c >/dev/null 2>&1

    bu set-config --file "$file" --unset BU_TEST_DROP >/dev/null 2>&1

    # Only the target pair is removed; the others remain sorted.
    local body
    body=$(sed -n '/^# >>> bu set-config managed block/,/^# <<< bu set-config managed block/p' "$file" | grep '^BU_TEST_')
    assert_equal "$body" $'BU_TEST_KEEP1=a\nBU_TEST_KEEP2=b'
    ! grep -q '^BU_TEST_DROP=' "$file"
}

function test_set_config_degenerate_markers_refused { #@test
    local file="$BATS_TEST_TMPDIR/settings.sh"

    # Opener without closer.
    printf '# >>> bu set-config managed block -- do not hand-edit inside\n' > "$file"
    printf 'BU_TEST_X=1\n' >> "$file"
    local snapshot
    snapshot=$(cat "$file")
    run bu set-config --file "$file" BU_TEST_Y 2
    assert_failure
    assert_output --partial "inconsistent"
    assert_equal "$(cat "$file")" "$snapshot"

    # Duplicated opener.
    printf '# >>> bu set-config managed block -- do not hand-edit inside\n' > "$file"
    printf 'BU_TEST_X=1\n' >> "$file"
    printf '# >>> bu set-config managed block -- do not hand-edit inside\n' >> "$file"
    snapshot=$(cat "$file")
    run bu set-config --file "$file" BU_TEST_Y 2
    assert_failure
    assert_output --partial "inconsistent"
    assert_equal "$(cat "$file")" "$snapshot"
}

# ===========================================================================
# Embedder-redirected settings file (BU_CONFIG_LOCAL_FILE)
#
# `bu set-config` writes to BU_CONFIG_LOCAL_FILE so an embedding project can
# keep settings in its own tree, but execute-type commands re-run the
# entrypoint in a child process where the parent's non-exported variables are
# invisible. bu_entrypoint.sh must therefore re-read the file or persisted
# values silently revert to their registered defaults inside those commands.
# ===========================================================================

function test_config_local_file_embedder_sourced_in_child { #@test
    local settings="$BATS_TEST_TMPDIR/embedder_settings.sh"
    printf 'BU_TABLE_PAGER=preset:never\n' > "$settings"

    run env BU_CONFIG_LOCAL_FILE="$settings" bash -c \
        'source "$1"/bu_entrypoint.sh >/dev/null 2>&1; printf "%s" "$BU_TABLE_PAGER"' \
        _ "$DIR/.."
    assert_success
    assert_output "preset:never"
}

function test_config_local_file_set_config_roundtrips_to_child { #@test
    # The exact reported scenario: bu set-config persists to BU_CONFIG_LOCAL_FILE,
    # and a child (execute-type command) must observe the persisted value.
    bu set-config BU_TABLE_PAGER preset:never >/dev/null
    assert grep -q '^BU_TABLE_PAGER=preset:never$' "$BU_CONFIG_LOCAL_FILE"

    run env BU_CONFIG_LOCAL_FILE="$BU_CONFIG_LOCAL_FILE" bash -c \
        'source "$1"/bu_entrypoint.sh >/dev/null 2>&1; printf "%s" "$BU_TABLE_PAGER"' \
        _ "$DIR/.."
    assert_success
    assert_output "preset:never"
}

function test_config_local_file_sourced_once_when_default { #@test
    # Deterministic negative case: build a throwaway BU_DIR whose checkout-local
    # settings file records every source, so we can tell "sourced once" from
    # "sourced twice" without depending on the developer's real local config.
    local minrepo="$BATS_TEST_TMPDIR/minrepo"
    mkdir -p "$minrepo/config"
    ln -s "$DIR/../bu_entrypoint.sh" "$minrepo/bu_entrypoint.sh"
    ln -s "$DIR/../bu_custom_source.sh" "$minrepo/bu_custom_source.sh"
    ln -s "$DIR/../lib" "$minrepo/lib"
    ln -s "$DIR/../config/bu_config_static.sh" "$minrepo/config/bu_config_static.sh"
    ln -s "$DIR/../config/bu_config_dynamic.sh" "$minrepo/config/bu_config_dynamic.sh"
    cat > "$minrepo/config/bu_config_local.sh" <<'SCRIPT_EOF'
BU_SRC_COUNT=$(( ${BU_SRC_COUNT:-0} + 1 ))
printf '%s\n' "$BU_SRC_COUNT" >> "$BU_SRC_LOG"
BU_TABLE_PAGER=preset:never
SCRIPT_EOF

    # (a) Unset: the checkout-local file is the only settings file, sourced once.
    local log_unset="$BATS_TEST_TMPDIR/unset.log"
    run env -u BU_CONFIG_LOCAL_FILE BU_SRC_LOG="$log_unset" bash -c \
        'source "$1/bu_entrypoint.sh" >/dev/null 2>&1; printf "%s|%s" "$BU_TABLE_PAGER" "${BU_SRC_COUNT:-unset}"' \
        _ "$minrepo"
    assert_success
    assert_output "preset:never|1"
    assert_equal "$(grep -c . "$log_unset")" "1"

    # (b) Equal to the checkout-local path: still sourced exactly once (the
    # embedder re-read must be skipped, not a second source).
    local log_equal="$BATS_TEST_TMPDIR/equal.log"
    run env BU_CONFIG_LOCAL_FILE="$minrepo/config/bu_config_local.sh" BU_SRC_LOG="$log_equal" bash -c \
        'source "$1/bu_entrypoint.sh" >/dev/null 2>&1; printf "%s|%s" "$BU_TABLE_PAGER" "${BU_SRC_COUNT:-unset}"' \
        _ "$minrepo"
    assert_success
    assert_output "preset:never|1"
    assert_equal "$(grep -c . "$log_equal")" "1"

    # (c) A relative path that resolves to the checkout-local file is also
    # recognized and skipped (no double source).
    local log_relative="$BATS_TEST_TMPDIR/relative.log"
    run env BU_CONFIG_LOCAL_FILE="./config/bu_config_local.sh" BU_SRC_LOG="$log_relative" bash -c \
        'cd "$1" && source ./bu_entrypoint.sh >/dev/null 2>&1; printf "%s|%s" "$BU_TABLE_PAGER" "${BU_SRC_COUNT:-unset}"' \
        _ "$minrepo"
    assert_success
    assert_output "preset:never|1"
    assert_equal "$(grep -c . "$log_relative")" "1"
}

# ===========================================================================
# Settings precedence and provenance
#
# Exported variables > settings files > registered defaults. A config phase
# saves exported values before sourcing its settings files, resets unexported
# values, restores the exported ones afterwards, then applies defaults from a
# vars file generated from the registry.
# ===========================================================================

# Throwaway BU_DIR without the developer's config/bu_config_local.sh (see
# test_config_local_file_sourced_once_when_default)
__config_test_minrepo()
{
    local -r minrepo=$1
    mkdir -p "$minrepo/config" "$minrepo/site"
    ln -s "$DIR/../bu_entrypoint.sh" "$minrepo/bu_entrypoint.sh"
    ln -s "$DIR/../bu_custom_source.sh" "$minrepo/bu_custom_source.sh"
    ln -s "$DIR/../lib" "$minrepo/lib"
    ln -s "$DIR/../config/bu_config_static.sh" "$minrepo/config/bu_config_static.sh"
    ln -s "$DIR/../config/bu_config_dynamic.sh" "$minrepo/config/bu_config_dynamic.sh"
}

function test_config_exported_value_beats_settings_file { #@test
    local settings="$BATS_TEST_TMPDIR/settings.sh"
    printf 'BU_TABLE_PAGER=preset:never\n' > "$settings"

    run env BU_CONFIG_LOCAL_FILE="$settings" BU_TABLE_PAGER=preset:less bash -c \
        'source "$1"/bu_entrypoint.sh >/dev/null 2>&1; printf "%s|%s" "$BU_TABLE_PAGER" "${BU_CONFIG_ORIGIN[BU_TABLE_PAGER]}"' \
        _ "$DIR/.."
    assert_success
    assert_output "preset:less|env"
}

function test_config_exported_bootstrap_verbose_wins_during_bootstrap { #@test
    # BU_BOOTSTRAP_VERBOSE is a static setting (bu_config_local.static.sh):
    # final before the rest of BashTab is sourced, and an exported value wins.
    local settings="$BATS_TEST_TMPDIR/settings.sh"
    printf 'BU_BOOTSTRAP_VERBOSE=true\n' > "$BATS_TEST_TMPDIR/settings.static.sh"

    # Control: the settings file alone turns bootstrap logging on
    env -u BU_BOOTSTRAP_VERBOSE BU_CONFIG_LOCAL_FILE="$settings" bash -c \
        'source "$1"/bu_entrypoint.sh >/dev/null 2>"$2"' _ "$DIR/.." "$BATS_TEST_TMPDIR/on.log"
    grep -q '^DEBUG' "$BATS_TEST_TMPDIR/on.log"

    env BU_CONFIG_LOCAL_FILE="$settings" BU_BOOTSTRAP_VERBOSE=false bash -c \
        'source "$1"/bu_entrypoint.sh >/dev/null 2>"$2"' _ "$DIR/.." "$BATS_TEST_TMPDIR/off.log"
    ! grep -q '^DEBUG' "$BATS_TEST_TMPDIR/off.log"
}

function test_config_unexported_value_does_not_beat_settings { #@test
    # Only exported values win, on the first activation too
    local minrepo="$BATS_TEST_TMPDIR/minrepo"
    __config_test_minrepo "$minrepo"
    printf 'BU_TABLE_PAGER=preset:never\n' > "$minrepo/config/bu_config_local.sh"

    run env -u BU_QUERY_EXECUTOR -u BU_TABLE_PAGER -u BU_CONFIG_LOCAL_FILE bash -c \
        'BU_QUERY_EXECUTOR=combined; BU_TABLE_PAGER=bat
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        [[ "$BU_QUERY_EXECUTOR" == "${BU_CONFIG_PROPERTIES[BU_QUERY_EXECUTOR,default]}" ]] && q=default
        printf "%s|%s" "${q:-$BU_QUERY_EXECUTOR}" "$BU_TABLE_PAGER"' \
        _ "$minrepo"
    assert_success
    assert_output "default|preset:never"
}

function test_config_reactivation_rereads_settings_file { #@test
    local minrepo="$BATS_TEST_TMPDIR/minrepo"
    __config_test_minrepo "$minrepo"
    local settings="$minrepo/config/bu_config_local.sh"
    printf 'BU_TABLE_PAGER=preset:never\n' > "$settings"

    # Edited value applies, then a removed line falls back to the default
    run env -u BU_TABLE_PAGER BU_CONFIG_LOCAL_FILE="$settings" bash -c '
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        printf "BU_TABLE_PAGER=bat\n" > "$BU_CONFIG_LOCAL_FILE"
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        edited=$BU_TABLE_PAGER
        : > "$BU_CONFIG_LOCAL_FILE"
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        [[ "$BU_TABLE_PAGER" == "${BU_CONFIG_PROPERTIES[BU_TABLE_PAGER,default]}" ]] && removed=default
        printf "%s|%s" "$edited" "${removed:-$BU_TABLE_PAGER}"' \
        _ "$minrepo"
    assert_success
    assert_output "bat|default"
}

function test_config_reactivation_keeps_exported_resets_unexported { #@test
    local settings="$BATS_TEST_TMPDIR/settings.sh"
    printf 'BU_TABLE_PAGER=preset:never\nBU_QUERY_EXECUTOR=pipeline\n' > "$settings"

    run env -u BU_TABLE_PAGER -u BU_QUERY_EXECUTOR BU_CONFIG_LOCAL_FILE="$settings" bash -c '
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        export BU_TABLE_PAGER=preset:less
        BU_QUERY_EXECUTOR=combined
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        printf "%s|%s|%s|%s" "$BU_TABLE_PAGER" "${BU_CONFIG_ORIGIN[BU_TABLE_PAGER]}" \
            "$BU_QUERY_EXECUTOR" "${BU_CONFIG_ORIGIN[BU_QUERY_EXECUTOR]}"' \
        _ "$DIR/.."
    assert_success
    assert_output "preset:less|env|pipeline|local"
}

function test_config_set_config_twice_then_reactivate_and_resource { #@test
    local settings="$BATS_TEST_TMPDIR/settings.sh"

    run env -u BU_TABLE_PAGER BU_CONFIG_LOCAL_FILE="$settings" bash -c '
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        bu set-config BU_TABLE_PAGER preset:less >/dev/null 2>&1
        bu set-config BU_TABLE_PAGER preset:never >/dev/null 2>&1
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        reactivated=$BU_TABLE_PAGER
        BU_TABLE_PAGER=other
        source "$BU_CONFIG_LOCAL_FILE"
        printf "%s|%s" "$reactivated" "$BU_TABLE_PAGER"' \
        _ "$DIR/.."
    assert_success
    assert_output "preset:never|preset:never"
}

function test_config_site_file_provenance { #@test
    local minrepo="$BATS_TEST_TMPDIR/minrepo"
    __config_test_minrepo "$minrepo"
    printf '# site glue\nBU_TABLE_PAGER=preset:never\n' > "$minrepo/site/10-test.sh"

    run env -u BU_TABLE_PAGER -u BU_CONFIG_LOCAL_FILE bash -c \
        'source "$1/bu_entrypoint.sh" >/dev/null 2>&1; printf "%s|%s|%s" "$BU_TABLE_PAGER" "${BU_CONFIG_ORIGIN[BU_TABLE_PAGER]}" "${BU_CONFIG_SOURCE_FILE[BU_TABLE_PAGER]}"' \
        _ "$minrepo"
    assert_success
    assert_output "preset:never|site|$minrepo/site/10-test.sh"

    # An exported value beats site glue too
    run env -u BU_CONFIG_LOCAL_FILE BU_TABLE_PAGER=preset:less bash -c \
        'source "$1/bu_entrypoint.sh" >/dev/null 2>&1; printf "%s|%s" "$BU_TABLE_PAGER" "${BU_CONFIG_ORIGIN[BU_TABLE_PAGER]}"' \
        _ "$minrepo"
    assert_success
    assert_output "preset:less|env"
}

function test_get_config_origin_and_location { #@test
    local out

    # local: the managed block line (line 1 is the opener)
    bu set-config BU_TABLE_PAGER preset:never >/dev/null 2>&1
    # shell: changed after activation
    if [[ "$BU_QUERY_EXECUTOR" == combined ]]; then BU_QUERY_EXECUTOR=pipeline; else BU_QUERY_EXECUTOR=combined; fi
    # default: registered and assigned outside any settings file
    bu_config_register BU_TEST_PROVENANCE --default x --hint "provenance test"
    BU_TEST_PROVENANCE=x

    out=$(bu get-config --format jsonl 2>/dev/null)
    assert_equal "$(jq -r 'select(.name == "BU_TABLE_PAGER") | "\(.origin)|\(.location)"' <<<"$out")" \
        "local|$BU_CONFIG_LOCAL_FILE:2"
    assert_equal "$(jq -r 'select(.name == "BU_QUERY_EXECUTOR") | "\(.origin)|\(.location)"' <<<"$out")" \
        "shell|"
    assert_equal "$(jq -r 'select(.name == "BU_TEST_PROVENANCE") | .origin' <<<"$out")" default
    [[ "$(jq -r 'select(.name == "BU_TEST_PROVENANCE") | .location' <<<"$out")" == *:[0-9]* ]]

    # A core setting's declaration is the first line of its register call
    local line
    line=$(grep -n '^bu_config_register BU_QUERY_EXECUTOR' "$BU_DIR/config/bu_config_dynamic.sh" | cut -d: -f1)
    assert_equal "${BU_CONFIG_PROPERTIES[BU_QUERY_EXECUTOR,defined_at]}" "$BU_DIR/config/bu_config_dynamic.sh:$line"

    # --unset returns provenance to the default
    bu set-config --unset BU_TABLE_PAGER >/dev/null 2>&1
    out=$(bu get-config --format jsonl 2>/dev/null)
    assert_equal "$(jq -r 'select(.name == "BU_TABLE_PAGER") | .origin' <<<"$out")" default
}

function test_config_vars_file_generated_from_registry { #@test
    __bu_config_vars_file main
    local file=$BU_RET
    assert_equal "$file" "$BU_OUT_DIR/cache/config-vars/${BU_TOP_LEVEL_MODULE:-default}/${BU_DIR//\//_}/main.sh"
    assert [ -f "$file" ]
    # One documented NAME=${NAME:-default} line per main-phase setting
    grep -qxF 'BU_QUERY_EXECUTOR=${BU_QUERY_EXECUTOR:-pipeline}' "$file"
    grep -qxF 'BU_OUTPUT_FORMAT=${BU_OUTPUT_FORMAT:-}' "$file"
    grep -q '^# Query executor' "$file"
    grep -q "declared: $BU_DIR/config/bu_config_dynamic.sh:[0-9]*\$" "$file"
    assert_equal "$(grep -c '^BU_[A-Z0-9_]*=' "$file")" \
        "$(for k in "${!BU_CONFIG_PROPERTIES[@]}"; do [[ "$k" == *,phase && "${BU_CONFIG_PROPERTIES[$k]}" == main ]] && echo x; done | grep -c .)"
    # Unchanged registry: the file is not rewritten
    local before
    before=$(ls -li "$file")
    bu_config_phase_begin main
    source "$BU_DIR"/config/bu_config_dynamic.sh
    bu_config_phase_end main
    assert_equal "$(ls -li "$file")" "$before"
}

function test_config_custom_phase { #@test
    local phase_file="${BU_CONFIG_LOCAL_FILE%.sh}.extra.sh"
    printf 'BU_TEST_EXTRA_A=from-file\nBU_LOG_LVL=0\n' > "$phase_file"
    local lvl_before=$BU_LOG_LVL

    export BU_TEST_EXTRA_C=exported
    bu_config_phase_begin extra
    bu_config_register BU_TEST_EXTRA_A --default a --hint "extra a"
    bu_config_register BU_TEST_EXTRA_B --default b --hint "extra b"
    bu_config_register BU_TEST_EXTRA_C --default c --hint "extra c"
    bu_config_phase_end extra 2>"$BATS_TEST_TMPDIR/err"

    # The phase's own file, defaults, exported value; main's setting protected
    assert_equal "$BU_TEST_EXTRA_A|${BU_CONFIG_ORIGIN[BU_TEST_EXTRA_A]}" "from-file|local"
    assert_equal "$BU_TEST_EXTRA_B" b
    assert_equal "$BU_TEST_EXTRA_C|${BU_CONFIG_ORIGIN[BU_TEST_EXTRA_C]}" "exported|env"
    assert_equal "$BU_LOG_LVL" "$lvl_before"
    grep -q "ignoring assignment to BU_LOG_LVL, a setting of config phase 'main'" "$BATS_TEST_TMPDIR/err"
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_EXTRA_A,phase]}" extra

    # A setting belongs to one phase
    run bu_config_register BU_LOG_LVL --default 1
    assert_success
    bu_config_phase_begin other
    run bu_config_register BU_TEST_EXTRA_A --default z
    assert_failure
    bu_config_phase_end other

    # Running the phase again drops settings no longer registered
    bu_config_phase_begin extra
    bu_config_register BU_TEST_EXTRA_A --default a --hint "extra a"
    bu_config_phase_end extra 2>/dev/null
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_EXTRA_B,registered]:-}" ""
    [[ ! -v BU_TEST_EXTRA_B ]]
    assert_equal "$BU_TEST_EXTRA_C" exported
}

# ===========================================================================
# Static config phase: resolved once per shell, exported, final
# ===========================================================================

function test_config_static_setting_from_static_file { #@test
    local settings="$BATS_TEST_TMPDIR/settings.sh"
    printf 'BU_EXIT_HANDLER_VSCODE_POPUP=true\n' > "$BATS_TEST_TMPDIR/settings.static.sh"
    # A static setting in the regular settings file is ignored, with a warning
    printf 'BU_OUT_DIR=/tmp/not-here\n' > "$settings"

    run --separate-stderr env -u BU_EXIT_HANDLER_VSCODE_POPUP BU_CONFIG_LOCAL_FILE="$settings" bash -c '
        source "$1"/bu_entrypoint.sh >/dev/null
        printf "%s|%s|%s|%s" "$BU_EXIT_HANDLER_VSCODE_POPUP" "${BU_CONFIG_ORIGIN[BU_EXIT_HANDLER_VSCODE_POPUP]}" \
            "${BU_EXIT_HANDLER_VSCODE_POPUP@a}" "$BU_OUT_DIR"' \
        _ "$DIR/.."
    assert_success
    assert_output "true|local|x|${BU_OUT_DIR}"
    [[ "$stderr" == *"ignoring assignment to BU_OUT_DIR, a setting of config phase 'static'"* ]]
}

function test_config_static_setting_final_for_the_shell { #@test
    run --separate-stderr env BU_CONFIG_LOCAL_FILE="$BATS_TEST_TMPDIR/settings.sh" bash -c '
        source "$1"/bu_entrypoint.sh >/dev/null
        first=$BU_OUT_DIR
        export BU_OUT_DIR=/tmp/changed-later
        source "$1"/bu_entrypoint.sh >/dev/null
        [[ "$BU_OUT_DIR" == "$first" ]] && echo kept' \
        _ "$DIR/.."
    assert_success
    assert_output kept
    [[ "$stderr" == *"BU_OUT_DIR is a static setting, final for this shell"* ]]
}

function test_config_static_unexported_value_counts { #@test
    # Set before the static phase, without export: still the user's (statics
    # are exported once final, so child processes see the same value)
    run env -u BU_EXIT_HANDLER_VSCODE_POPUP bash -c '
        BU_EXIT_HANDLER_VSCODE_POPUP=true
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        printf "%s|%s|%s" "$BU_EXIT_HANDLER_VSCODE_POPUP" "${BU_CONFIG_ORIGIN[BU_EXIT_HANDLER_VSCODE_POPUP]}" \
            "$(bash -c "printf %s \"\$BU_EXIT_HANDLER_VSCODE_POPUP\"")"' \
        _ "$DIR/.."
    assert_success
    assert_output "true|shell|true"
}

function test_config_env_only_settings { #@test
    # Settings files cannot set them...
    printf 'BU_TOP_LEVEL_MODULE=from-file\n' > "$BATS_TEST_TMPDIR/settings.static.sh"
    run --separate-stderr env BU_TOP_LEVEL_MODULE=from-env BU_CONFIG_LOCAL_FILE="$BATS_TEST_TMPDIR/settings.sh" bash -c '
        source "$1"/bu_entrypoint.sh >/dev/null
        printf "%s|%s" "$BU_TOP_LEVEL_MODULE" "${BU_CONFIG_ORIGIN[BU_TOP_LEVEL_MODULE]}"' \
        _ "$DIR/.."
    assert_success
    assert_output "from-env|env"
    [[ "$stderr" == *"ignoring assignment to BU_TOP_LEVEL_MODULE, which only the environment can set"* ]]

    # ...and neither can bu set-config
    run bu set-config BU_CONFIG_LOCAL_FILE /tmp/x
    assert_failure
    assert_output --partial "can only be set in the environment"
}

function test_set_config_static_setting_writes_static_file { #@test
    local live=$BU_BOOTSTRAP_VERBOSE
    run bu set-config BU_BOOTSTRAP_VERBOSE true
    assert_success
    assert_output --partial "takes effect in a new shell"
    grep -qx 'BU_BOOTSTRAP_VERBOSE=true' "${BU_CONFIG_LOCAL_FILE%.sh}.static.sh"
    ! grep -q BU_BOOTSTRAP_VERBOSE "$BU_CONFIG_LOCAL_FILE" 2>/dev/null
    bu set-config BU_BOOTSTRAP_VERBOSE true >/dev/null
    assert_equal "$BU_BOOTSTRAP_VERBOSE" "$live"
}

function test_config_module_list_normalized_before_final { #@test
    run env BU_MODULE_LIST='a:1:/nonexistent/a.sh;b:1:/nonexistent/b.sh;a:1:/nonexistent/a.sh;;' bash -c '
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        printf "%s|%s" "$BU_MODULE_LIST" "${__BU_CONFIG_APPLIED[BU_MODULE_LIST]}"' \
        _ "$DIR/.."
    assert_success
    assert_output "a:1:/nonexistent/a.sh;b:1:/nonexistent/b.sh;|a:1:/nonexistent/a.sh;b:1:/nonexistent/b.sh;"
}

function test_config_static_reset_resolves_again { #@test
    # bu import-environment --reset-source: BashTab-set statics are dropped,
    # user-supplied ones kept, and the static phase runs again
    run env -u BU_EXIT_HANDLER_VSCODE_POPUP BU_CONFIG_LOCAL_FILE="$BATS_TEST_TMPDIR/settings.sh" bash -c '
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        printf "BU_EXIT_HANDLER_VSCODE_POPUP=true\n" > "${BU_CONFIG_LOCAL_FILE%.sh}.static.sh"
        __bu_config_static_reset
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        printf "%s|%s|%s" "$BU_EXIT_HANDLER_VSCODE_POPUP" "${BU_CONFIG_ORIGIN[BU_EXIT_HANDLER_VSCODE_POPUP]}" \
            "${BU_CONFIG_ORIGIN[BU_CONFIG_LOCAL_FILE]}"' \
        _ "$DIR/.."
    assert_success
    assert_output "true|local|env"
}

# ===========================================================================
# User-defined phases with variants (profiles) and module config files
# ===========================================================================

# A profile-style phase: shared settings with per-variant defaults, plus a
# setting that exists only for one variant
__config_test_profile_phase()
{
    local -r variant=$1
    bu_config_phase_begin profile --variant "$variant" --prefix BU_TEST_PROFILE_
    bu_config_register BU_TEST_PROFILE_URL --default https://default.example \
        --default-for dev https://dev.example --default-for prod https://prod.example \
        --hint "Endpoint"
    bu_config_register BU_TEST_PROFILE_REGION --default us --hint "Region"
    if [[ "$variant" == dev ]]
    then
        bu_config_register BU_TEST_PROFILE_MOCK_PORT --default 8080 --hint "Dev-only mock port"
    fi
    bu_config_phase_end profile 2>/dev/null
}

function test_config_phase_variants { #@test
    local base=${BU_CONFIG_LOCAL_FILE%.sh}
    printf 'BU_TEST_PROFILE_REGION=eu\n' > "$base.profile.sh"
    printf 'BU_TEST_PROFILE_REGION=ap\n' > "$base.profile.prod.sh"

    __config_test_profile_phase dev
    assert_equal "$BU_TEST_PROFILE_URL" https://dev.example
    assert_equal "$BU_TEST_PROFILE_REGION|${BU_CONFIG_SOURCE_FILE[BU_TEST_PROFILE_REGION]}" "eu|$base.profile.sh"
    assert_equal "$BU_TEST_PROFILE_MOCK_PORT" 8080
    __bu_config_vars_file profile
    [[ "$BU_RET" == */profile.dev.sh && -f "$BU_RET" ]]
    assert_equal "$(bu get-config --format jsonl 2>/dev/null | jq -r 'select(.name == "BU_TEST_PROFILE_URL") | .phase')" "profile[dev]"

    # Switching variant: the variant file wins over the shared one, and
    # dev-only settings disappear
    __config_test_profile_phase prod
    assert_equal "$BU_TEST_PROFILE_URL" https://prod.example
    assert_equal "$BU_TEST_PROFILE_REGION" ap
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_PROFILE_MOCK_PORT,registered]:-}" ""
    [[ ! -v BU_TEST_PROFILE_MOCK_PORT ]]

    # The phase prefix is enforced
    bu_config_phase_begin profile --variant prod --prefix BU_TEST_PROFILE_
    run bu_config_register BU_TEST_OTHER --default x
    assert_failure
    bu_config_phase_end profile 2>/dev/null

    # Unloading drops the phase entirely
    bu_config_phase_unload profile
    [[ ! -v BU_TEST_PROFILE_URL ]]
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_PROFILE_URL,registered]:-}" ""
}

function test_set_config_variants { #@test
    local base=${BU_CONFIG_LOCAL_FILE%.sh}
    __config_test_profile_phase dev

    # Active variant: its own file, applied live
    bu set-config BU_TEST_PROFILE_REGION eu >/dev/null 2>&1
    grep -qx 'BU_TEST_PROFILE_REGION=eu' "$base.profile.dev.sh"
    assert_equal "$BU_TEST_PROFILE_REGION|${BU_CONFIG_ORIGIN[BU_TEST_PROFILE_REGION]}" "eu|local"

    # Another variant, or all variants: stored, applied when the phase runs
    run bu set-config --variant prod BU_TEST_PROFILE_REGION ap
    assert_success
    assert_output --partial "next time config phase 'profile' runs with variant prod"
    grep -qx 'BU_TEST_PROFILE_REGION=ap' "$base.profile.prod.sh"
    bu set-config --all-variants BU_TEST_PROFILE_REGION sa >/dev/null 2>&1
    grep -qx 'BU_TEST_PROFILE_REGION=sa' "$base.profile.sh"
    assert_equal "$BU_TEST_PROFILE_REGION" eu

    __config_test_profile_phase prod
    assert_equal "$BU_TEST_PROFILE_REGION" ap
}

# ===========================================================================
# Extra settings files of a phase (bu_config_phase_begin --settings-file)
# ===========================================================================

# A phase with its own layers: extra args go to bu_config_phase_begin
__config_test_layered_phase()
{
    bu_config_phase_begin layered --prefix BU_TEST_LAYER_ "$@"
    bu_config_register BU_TEST_LAYER_ALL --default d --hint "In every file"
    bu_config_register BU_TEST_LAYER_UE --default d --hint "In the user and embedder files"
    bu_config_register BU_TEST_LAYER_U --default d --hint "In the user file only"
    bu_config_phase_end layered 2>"$BATS_TEST_TMPDIR/err"
}

__config_test_layer_row()
{
    bu get-config --format jsonl 2>/dev/null | jq -r --arg n "$1" 'select(.name == $n) | "\(.origin)|\(.location)"'
}

function test_config_phase_settings_file_order { #@test
    local base=${BU_CONFIG_LOCAL_FILE%.sh}
    local u=$BATS_TEST_TMPDIR/user.sh p=$BATS_TEST_TMPDIR/profile.sh
    printf 'BU_TEST_LAYER_ALL=u\nBU_TEST_LAYER_UE=u\nBU_TEST_LAYER_U=u\n' > "$u"
    printf 'BU_TEST_LAYER_ALL=e\nBU_TEST_LAYER_UE=e\n' > "$base.layered.sh"
    printf '# profile overrides\nBU_TEST_LAYER_ALL=p\n' > "$p"

    __config_test_layered_phase --settings-file "user:$u" --settings-file local --settings-file "profile:$p"
    assert_equal "$BU_TEST_LAYER_ALL|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_ALL]}|${BU_CONFIG_SOURCE_FILE[BU_TEST_LAYER_ALL]}" "p|profile|$p"
    assert_equal "$BU_TEST_LAYER_UE|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_UE]}|${BU_CONFIG_SOURCE_FILE[BU_TEST_LAYER_UE]}" "e|local|$base.layered.sh"
    assert_equal "$BU_TEST_LAYER_U|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_U]}|${BU_CONFIG_SOURCE_FILE[BU_TEST_LAYER_U]}" "u|user|$u"
    assert_equal "$(__config_test_layer_row BU_TEST_LAYER_ALL)" "profile|$p:2"
    assert_equal "$(__config_test_layer_row BU_TEST_LAYER_U)" "user|$u:3"
    [[ ! -s "$BATS_TEST_TMPDIR/err" ]]

    # The local token placed first: the user file beats the embedder file
    __config_test_layered_phase --settings-file local --settings-file "user:$u" --settings-file "profile:$p"
    assert_equal "$BU_TEST_LAYER_UE|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_UE]}" "u|user"

    # No local token: the built-in files come first, as before
    __config_test_layered_phase --settings-file "user:$u"
    assert_equal "$BU_TEST_LAYER_UE|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_UE]}" "u|user"
    assert_equal "$BU_TEST_LAYER_ALL|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_ALL]}" "u|user"

    # ORIGIN omitted: local
    __config_test_layered_phase --settings-file local --settings-file "$p"
    assert_equal "$BU_TEST_LAYER_ALL|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_ALL]}|${BU_CONFIG_SOURCE_FILE[BU_TEST_LAYER_ALL]}" "p|local|$p"
}

function test_config_phase_settings_file_reproduction { #@test
    run --separate-stderr env -i HOME="$HOME" PATH="$PATH" USER="$USER" TERM=dumb bash -c '
        cd "$1" || exit 1
        export BU_OUT_DIR=$2
        export BU_CONFIG_LOCAL_FILE=$BU_OUT_DIR/settings.sh
        source ./bu_entrypoint.sh >/dev/null 2>&1
        mkdir -p "$BU_OUT_DIR/users/$USER" "$BU_OUT_DIR/profiles/dev"
        printf "MYAPP_REGION=eu\nMYAPP_BUILD=release\n" > "$BU_OUT_DIR/users/$USER/settings.sh"
        printf "MYAPP_BUILD=debug\n"                    > "$BU_OUT_DIR/profiles/dev/overrides.sh"
        printf "MYAPP_REGION=us\n"                      > "$BU_OUT_DIR/settings.profile.sh"
        BU_CONFIG_NAME_PREFIXES+=(MYAPP_)
        bu_config_phase_begin profile --variant dev --prefix MYAPP_ \
            --settings-file "user:$BU_OUT_DIR/users/$USER/settings.sh" \
            --settings-file local \
            --settings-file "profile:$BU_OUT_DIR/profiles/dev/overrides.sh"
        bu_config_register MYAPP_REGION --default ap   --hint "Region"
        bu_config_register MYAPP_BUILD  --default none --hint "Build flavour"
        bu_config_phase_end profile
        echo "REGION=$MYAPP_REGION (${BU_CONFIG_ORIGIN[MYAPP_REGION]:-default}) BUILD=$MYAPP_BUILD (${BU_CONFIG_ORIGIN[MYAPP_BUILD]:-default})"' \
        _ "$DIR/.." "$BATS_TEST_TMPDIR/out"
    assert_success
    assert_output "REGION=us (local) BUILD=debug (profile)"
}

function test_config_phase_settings_file_missing_and_protected { #@test
    local p=$BATS_TEST_TMPDIR/profile.sh
    local lvl_before=$BU_LOG_LVL top_before=$BU_TOP_LEVEL_MODULE
    printf 'BU_TEST_LAYER_ALL=p\n' > "$p"

    # A missing file is skipped silently
    __config_test_layered_phase --settings-file "user:$BATS_TEST_TMPDIR/missing.sh" --settings-file "profile:$p"
    assert_equal "$BU_TEST_LAYER_ALL|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_ALL]}" "p|profile"
    [[ ! -s "$BATS_TEST_TMPDIR/err" ]]

    # Another phase's settings (final, env-only static) are reverted; an
    # exported value survives every file
    printf 'BU_TEST_LAYER_ALL=p\nBU_TEST_LAYER_U=p\nBU_LOG_LVL=0\nBU_TOP_LEVEL_MODULE=from-file\n' > "$p"
    export BU_TEST_LAYER_U=exported
    __config_test_layered_phase --settings-file "profile:$p"
    assert_equal "$BU_LOG_LVL" "$lvl_before"
    assert_equal "$BU_TOP_LEVEL_MODULE" "$top_before"
    grep -q "$p: ignoring assignment to BU_LOG_LVL, a setting of config phase 'main'" "$BATS_TEST_TMPDIR/err"
    grep -q "$p: ignoring assignment to BU_TOP_LEVEL_MODULE, a setting of config phase 'static'" "$BATS_TEST_TMPDIR/err"
    assert_equal "$BU_TEST_LAYER_U|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_U]}" "exported|env"
    assert_equal "$BU_TEST_LAYER_ALL|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_ALL]}" "p|profile"

    # Static phases take extra files too; an env-only setting of the phase
    # itself is protected as in its built-in files
    printf 'BU_TEST_LAYER_STATIC=from-file\nBU_TEST_LAYER_ENV=from-file\n' > "$p"
    bu_config_phase_begin layeredstatic --static --settings-file "profile:$p"
    bu_config_register BU_TEST_LAYER_STATIC --default d --hint "Static"
    bu_config_register BU_TEST_LAYER_ENV --env-only --default d --hint "Env only"
    bu_config_phase_end layeredstatic 2>"$BATS_TEST_TMPDIR/err"
    assert_equal "$BU_TEST_LAYER_ENV" d
    grep -q "$p: ignoring assignment to BU_TEST_LAYER_ENV, which only the environment can set" "$BATS_TEST_TMPDIR/err"
    assert_equal "$BU_TEST_LAYER_STATIC|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_STATIC]}|${BU_TEST_LAYER_STATIC@a}" "from-file|profile|x"
}

function test_config_phase_settings_file_variants { #@test
    local base=${BU_CONFIG_LOCAL_FILE%.sh}
    local u=$BATS_TEST_TMPDIR/user.sh p=$BATS_TEST_TMPDIR/profile.sh
    printf 'BU_TEST_LAYER_ALL=u\nBU_TEST_LAYER_U=u\n' > "$u"
    printf 'BU_TEST_LAYER_ALL=e\n' > "$base.layered.sh"
    printf 'BU_TEST_LAYER_ALL=v\n' > "$base.layered.dev.sh"
    printf 'BU_TEST_LAYER_ALL=p\n' > "$p"

    # The variant file runs inside the local group, after the shared one
    __config_test_layered_phase --variant dev --settings-file "user:$u" --settings-file local
    assert_equal "$BU_TEST_LAYER_ALL|${BU_CONFIG_SOURCE_FILE[BU_TEST_LAYER_ALL]}" "v|$base.layered.dev.sh"
    assert_equal "$BU_TEST_LAYER_U|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_U]}" "u|user"

    # Running it again with another variant and list uses the new list only
    __config_test_layered_phase --variant prod --settings-file "profile:$p"
    assert_equal "$BU_TEST_LAYER_ALL|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_ALL]}" "p|profile"
    assert_equal "$BU_TEST_LAYER_U|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_U]:-default}" "d|default"
    bu_config_phase_files layered
    assert_equal "${BU_RET[*]}" "local:$BU_DIR/config/bu_config_local.layered.sh local:$base.layered.sh local:$BU_DIR/config/bu_config_local.layered.prod.sh local:$base.layered.prod.sh profile:$p"
}

function test_config_phase_settings_file_validation { #@test
    local p=$BATS_TEST_TMPDIR/profile.sh
    printf 'BU_TEST_LAYER_ALL=p\n' > "$p"
    bu_config_phase_begin layered --prefix BU_TEST_LAYER_ --settings-file "nope!:$p" --settings-file "env:$p" \
        --settings-file local --settings-file local --settings-file '' --settings-file "user:" 2>"$BATS_TEST_TMPDIR/err"
    assert_equal "$(grep -c 'bu_config_phase_begin: --settings-file' "$BATS_TEST_TMPDIR/err")" 5
    grep -q "invalid origin\[nope!\]" "$BATS_TEST_TMPDIR/err"
    grep -q "origin\[env\] is reserved" "$BATS_TEST_TMPDIR/err"
    grep -q "local given twice" "$BATS_TEST_TMPDIR/err"
    assert_equal "$__BU_CONFIG_OPEN_PHASE" layered
    bu_config_register BU_TEST_LAYER_ALL --default d --hint "In every file"
    bu_config_phase_end layered 2>/dev/null
    assert_equal "${BU_CONFIG_PHASE_STATE[layered]}|$BU_TEST_LAYER_ALL" "final|d"
    bu_config_phase_files layered
    assert_equal "${BU_RET[*]}" "local:$BU_DIR/config/bu_config_local.layered.sh local:${BU_CONFIG_LOCAL_FILE%.sh}.layered.sh"
}

function test_config_phase_files_lists_entries { #@test
    local base=${BU_CONFIG_LOCAL_FILE%.sh} p=$BATS_TEST_TMPDIR/profile.sh
    local missing=$BATS_TEST_TMPDIR/missing.sh
    : > "$p"
    # Relative paths are resolved when the phase begins
    mkdir -p "$BATS_TEST_TMPDIR/cwd"
    cd "$BATS_TEST_TMPDIR/cwd"
    bu_config_phase_begin layered --variant dev --settings-file "user:$missing" --settings-file local \
        --settings-file "profile:$p" --settings-file rel:sub/x:y.sh
    cd /
    bu_config_phase_end layered 2>/dev/null
    bu_config_phase_files layered
    local -a expected=(
        "user:$missing"
        "local:$BU_DIR/config/bu_config_local.layered.sh"
        "local:$base.layered.sh"
        "local:$BU_DIR/config/bu_config_local.layered.dev.sh"
        "local:$base.layered.dev.sh"
        "profile:$p"
        "rel:$BATS_TEST_TMPDIR/cwd/sub/x:y.sh"
    )
    assert_equal "$(printf '%s\n' "${BU_RET[@]}")" "$(printf '%s\n' "${expected[@]}")"
    # bu_config_phase_end reads only the existing ones
    __bu_config_phase_files layered
    assert_equal "${BU_RET[*]}" "profile:$p"
}

function test_set_config_declared_settings_file { #@test
    local p=$BATS_TEST_TMPDIR/profile.sh
    printf 'BU_TEST_LAYER_ALL=p\n' > "$p"
    __config_test_layered_phase --settings-file local --settings-file "profile:$p"

    bu set-config --file "$p" BU_TEST_LAYER_U pval >/dev/null 2>&1
    assert_equal "$BU_TEST_LAYER_U|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_U]}|${BU_CONFIG_SOURCE_FILE[BU_TEST_LAYER_U]}" "pval|profile|$p"
    local line
    line=$(grep -n '^BU_TEST_LAYER_U=pval$' "$p" | cut -d: -f1)
    [[ -n "$line" ]]
    assert_equal "$(__config_test_layer_row BU_TEST_LAYER_U)" "profile|$p:$line"

    # The next resolution reports the same
    __config_test_layered_phase --settings-file local --settings-file "profile:$p"
    assert_equal "$BU_TEST_LAYER_U|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_U]}" "pval|profile"
    assert_equal "$(__config_test_layer_row BU_TEST_LAYER_U)" "profile|$p:$line"

    # An undeclared file is still a layer
    bu set-config --file "$BATS_TEST_TMPDIR/other.sh" BU_TEST_LAYER_UE oval >/dev/null 2>&1
    assert_equal "${BU_CONFIG_ORIGIN[BU_TEST_LAYER_UE]}" layer
}

__config_test_natural_layer_phase()
{
    bu_config_phase_begin layered --prefix BU_TEST_LAYER_ --variant dev --settings-file local \
        --settings-file "profile:$BATS_TEST_TMPDIR/profile.sh"
    bu_config_register BU_TEST_LAYER_P --default d --hint "Natural layer: the declared file" --layer prof
    bu_config_register BU_TEST_LAYER_S --default d --hint "Natural layer: the shared built-in file" --layer shared
    bu_config_register BU_TEST_LAYER_X --default d --hint "Natural layer: local"
    bu_config_phase_end layered 2>/dev/null
}

function test_set_config_layer_to_phase_settings_file { #@test
    local p=$BATS_TEST_TMPDIR/profile.sh shared=${BU_CONFIG_LOCAL_FILE%.sh}.layered.sh
    : > "$p"
    function _config_test_prof_layer() { echo "$BATS_TEST_TMPDIR/profile.sh"; }
    function _config_test_shared_layer() { echo "${BU_CONFIG_LOCAL_FILE%.sh}.layered.sh"; }
    bu_config_register_layer prof _config_test_prof_layer
    bu_config_register_layer shared _config_test_shared_layer
    __config_test_natural_layer_phase

    # The natural layer resolves to a declared file: its origin, applied live
    bu set-config BU_TEST_LAYER_P pval >/dev/null 2>&1
    assert_equal "$BU_TEST_LAYER_P|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_P]}|${BU_CONFIG_SOURCE_FILE[BU_TEST_LAYER_P]}" "pval|profile|$p"
    grep -q '^BU_TEST_LAYER_P=pval$' "$p"

    # --layer to the same file records the same origin
    bu set-config --layer prof BU_TEST_LAYER_X xval >/dev/null 2>&1
    assert_equal "$BU_TEST_LAYER_X|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_X]}|${BU_CONFIG_SOURCE_FILE[BU_TEST_LAYER_X]}" "xval|profile|$p"

    # The shared built-in file (not the active variant's own file) is local
    bu set-config BU_TEST_LAYER_S sval >/dev/null 2>&1
    assert_equal "$BU_TEST_LAYER_S|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_S]}|${BU_CONFIG_SOURCE_FILE[BU_TEST_LAYER_S]}" "sval|local|$shared"

    # The next resolution reports the same
    __config_test_natural_layer_phase
    assert_equal "$BU_TEST_LAYER_P|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_P]}" "pval|profile"
    assert_equal "$BU_TEST_LAYER_X|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_X]}" "xval|profile"
    assert_equal "$BU_TEST_LAYER_S|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_S]}|${BU_CONFIG_SOURCE_FILE[BU_TEST_LAYER_S]}" "sval|local|$shared"

    # A file the phase does not read is still a layer
    bu set-config --file "$BATS_TEST_TMPDIR/other.sh" BU_TEST_LAYER_X oval >/dev/null 2>&1
    assert_equal "$BU_TEST_LAYER_X|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_X]}" "oval|layer"
}

function test_config_phase_unload_forgets_settings_files { #@test
    local p=$BATS_TEST_TMPDIR/profile.sh
    printf 'BU_TEST_LAYER_ALL=p\n' > "$p"
    printf 'BU_TEST_LAYER_ALL=e\n' > "${BU_CONFIG_LOCAL_FILE%.sh}.layered.sh"
    __config_test_layered_phase --settings-file "profile:$p"
    assert_equal "$BU_TEST_LAYER_ALL" p
    bu_config_phase_unload layered
    [[ ! -v '__BU_CONFIG_PHASE_FILES[layered]' ]]

    __config_test_layered_phase
    assert_equal "$BU_TEST_LAYER_ALL|${BU_CONFIG_ORIGIN[BU_TEST_LAYER_ALL]}" "e|local"
    bu_config_phase_files layered
    assert_equal "${BU_RET[*]}" "local:$BU_DIR/config/bu_config_local.layered.sh local:${BU_CONFIG_LOCAL_FILE%.sh}.layered.sh"
}

function test_config_module_config_files { #@test
    local mod="$BATS_TEST_TMPDIR/mymod"
    mkdir -p "$mod"
    : > "$mod/mymod_bu_preinit.sh"
    cat > "$mod/mymod_bu_config.static.sh" <<'SCRIPT_EOF'
BU_CONFIG_NAME_PREFIXES+=(MYMOD_)
bu_config_register MYMOD_HOME --default "$BU_CURRENT_MODULE_DIR/home" --hint "static"
SCRIPT_EOF
    cat > "$mod/mymod_bu_config.sh" <<'SCRIPT_EOF'
bu_config_register MYMOD_COLOR --default blue --hint "main"
bu_config_register MYMOD_SIZE --default 1 --hint "main"
SCRIPT_EOF
    printf 'MYMOD_SIZE=2\n' > "$BATS_TEST_TMPDIR/settings.sh"

    run env BU_MODULE_LIST="mymod:0.1.0:$mod/mymod_bu_preinit.sh;" MYMOD_COLOR=red \
        BU_CONFIG_LOCAL_FILE="$BATS_TEST_TMPDIR/settings.sh" bash -c '
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        for n in MYMOD_HOME MYMOD_COLOR MYMOD_SIZE; do
            printf "%s=%s:%s:%s:%s " "$n" "${!n}" "${BU_CONFIG_PROPERTIES[$n,phase]}" \
                "${BU_CONFIG_ORIGIN[$n]:-default}" "${BU_CONFIG_PROPERTIES[$n,module]}"
        done' \
        _ "$DIR/.."
    assert_success
    assert_output "MYMOD_HOME=$mod/home:static:default:mymod MYMOD_COLOR=red:main:env:mymod MYMOD_SIZE=2:main:local:mymod "
}

# Throwaway modules for ordering tests: each NAME_bu_module.sh appends its
# entry and requires its dependencies; its config file and preinit append to
# $ORDER_LOG. Args: root, then "name:dep1,dep2" specs.
__config_test_modules()
{
    local -r root=$1
    shift
    local spec name deps dep
    for spec in "$@"
    do
        name=${spec%%:*}
        deps=${spec#*:}
        mkdir -p "$root/$name"
        {
            printf 'BU_MODULE_LIST+="%s:0.1.0:%s/%s/%s_bu_preinit.sh;"\n' "$name" "$root" "$name" "$name"
            for dep in ${deps//,/ }
            do
                printf 'bu_module_require %s --dir "%s/%s"\n' "$dep" "$root" "$dep"
            done
        } > "$root/$name/${name}_bu_module.sh"
        printf 'printf "config %%s\\n" %s >> "$ORDER_LOG"\n' "$name" > "$root/$name/${name}_bu_config.sh"
        printf 'printf "preinit %%s\\n" %s >> "$ORDER_LOG"\n' "$name" > "$root/$name/${name}_bu_preinit.sh"
    done
}

# Activate like a top-level project: TOP is listed first and requires DEPS.
# Prints the order log as one line.
__config_test_activate_modules()
{
    local -r root=$1 top=$2
    shift 2
    run --separate-stderr env ORDER_LOG="$BATS_TEST_TMPDIR/order.log" BU_TOP_LEVEL_MODULE="$top" bash -c '
        dir=$1 root=$2 top=$3
        shift 3
        source "$dir/lib/bu_module_require.sh"
        export BU_MODULE_LIST="$top:0.1.0:$root/$top/${top}_bu_preinit.sh;"
        for dep in "$@"; do bu_module_require "$dep" --dir "$root/$dep"; done
        source "$dir"/bu_entrypoint.sh >/dev/null
        paste -sd, "$ORDER_LOG"' \
        _ "$DIR/.." "$root" "$top" "$@"
}

function test_config_module_order_diamond { #@test
    local root="$BATS_TEST_TMPDIR/mods"
    __config_test_modules "$root" app: b:d c:d d:
    __config_test_activate_modules "$root" app b c
    assert_success
    # Dependencies first, the top-level module last; unrelated modules keep
    # their BU_MODULE_LIST order (b before c)
    assert_output "config d,config b,config c,config app,preinit d,preinit b,preinit c,preinit app"
}

function test_config_module_order_cycle { #@test
    local root="$BATS_TEST_TMPDIR/mods"
    __config_test_modules "$root" top: a:b b:a
    __config_test_activate_modules "$root" top a
    assert_success
    assert_output "config b,config a,config top,preinit b,preinit a,preinit top"
    assert_equal "$(grep -c 'Module dependency cycle: b requires a' <<<"$stderr")" 1
}

function test_config_late_module_registration_warns { #@test
    BU_CURRENT_MODULE=latemod
    run bu_config_register BU_TEST_LATE --default x
    assert_success
    assert_output --partial "registered outside a config phase (module latemod)"
}

# ===========================================================================
# bu edit-config actions (run inside the viewer; replayed in the caller)
# ===========================================================================

# Run __bu_config_edit_action for a setting in a subshell (like the viewer's
# process), queueing into $BATS_TEST_TMPDIR/queue.sh. Prints its output.
__config_test_edit()
{
    local -r name=$1 mode=$2
    (
        BU_TV_RECORD=$(bu get-config --format jsonl 2>/dev/null | jq -c --arg n "$name" 'select(.name == $n)')
        BU_CONFIG_EDIT_QUEUE="$BATS_TEST_TMPDIR/queue.sh"
        bu_tv_prompt() { BU_RET=$TEST_PROMPT_VALUE; }
        bu_tv_interactive() { echo "interactive: $*"; }
        __bu_config_edit_action "$mode" 2>&1
    )
}

function test_config_edit_action_queue_applies_in_caller { #@test
    : > "$BATS_TEST_TMPDIR/queue.sh"
    BU_QUERY_EXECUTOR=pipeline
    run __config_test_edit BU_QUERY_EXECUTOR cycle
    assert_success
    assert_output --partial "Set BU_QUERY_EXECUTOR=combined"
    # The subshell changed nothing here until the queue is replayed
    assert_equal "$BU_QUERY_EXECUTOR" pipeline
    builtin source "$BATS_TEST_TMPDIR/queue.sh"
    assert_equal "$BU_QUERY_EXECUTOR|${BU_CONFIG_ORIGIN[BU_QUERY_EXECUTOR]}|${BU_CONFIG_SOURCE_FILE[BU_QUERY_EXECUTOR]}" \
        "combined|local|$BU_CONFIG_LOCAL_FILE"

    : > "$BATS_TEST_TMPDIR/queue.sh"
    TEST_PROMPT_VALUE=ascii run __config_test_edit BU_TABLE_STYLE prompt
    assert_success
    __config_test_edit BU_QUERY_EXECUTOR unset >/dev/null
    builtin source "$BATS_TEST_TMPDIR/queue.sh"
    assert_equal "$BU_TABLE_STYLE|$BU_QUERY_EXECUTOR|${BU_CONFIG_ORIGIN[BU_QUERY_EXECUTOR]:-default}" "ascii|pipeline|default"
    grep -qx 'BU_TABLE_STYLE=ascii' "$BU_CONFIG_LOCAL_FILE"
    ! grep -q BU_QUERY_EXECUTOR "$BU_CONFIG_LOCAL_FILE"
}

function test_config_edit_action_cycles_bool_and_enum { #@test
    BU_OUT_STRICT=true
    run __config_test_edit BU_OUT_STRICT cycle
    assert_output --partial "Set BU_OUT_STRICT=false"
    # A name:mapped enum steps by name from the mapped current value
    BU_LOG_LVL=$BU_LOG_LVL_ERR
    run __config_test_edit BU_LOG_LVL cycle
    assert_output --partial "Set BU_LOG_LVL=$BU_LOG_LVL_SILENCE"
    BU_LOG_LVL=$BU_LOG_LVL_SILENCE
    run __config_test_edit BU_LOG_LVL cycle
    assert_output --partial "Set BU_LOG_LVL=$BU_LOG_LVL_TRACE"
    run __config_test_edit BU_REMOTE_SSH_DIR cycle
    assert_output --partial "takes any value"
}

function test_config_edit_action_static_and_env_only { #@test
    : > "$BATS_TEST_TMPDIR/queue.sh"
    run __config_test_edit BU_BOOTSTRAP_VERBOSE cycle
    assert_success
    assert_output --partial "takes effect in a new shell"
    # Static: stored for new shells, not queued for this one
    assert [ ! -s "$BATS_TEST_TMPDIR/queue.sh" ]
    run __config_test_edit BU_TOP_LEVEL_MODULE prompt
    assert_failure
    assert_output --partial "can only be set in the environment"
}

function test_config_edit_action_open { #@test
    bu set-config BU_TABLE_STYLE ascii >/dev/null 2>&1
    run __config_test_edit BU_TABLE_STYLE open
    assert_success
    assert_line --index 0 "interactive: ${VISUAL:-${EDITOR:-vi}} +2 $BU_CONFIG_LOCAL_FILE"
    # A default: where it is registered
    local line
    line=$(grep -n '^bu_config_register BU_QUERY_EXECUTOR' "$BU_DIR/config/bu_config_dynamic.sh" | cut -d: -f1)
    run __config_test_edit BU_QUERY_EXECUTOR open
    assert_line --index 0 "interactive: ${VISUAL:-${EDITOR:-vi}} +$line $BU_DIR/config/bu_config_dynamic.sh"
    # Changed in the shell: nowhere to open
    BU_OUT_VALIDATION=off
    run __config_test_edit BU_OUT_VALIDATION open
    assert_output --partial "no settings file to open (origin"
}

# ===========================================================================
# Documentation/registry default consistency
# ===========================================================================

function test_docs_config_defaults_match_registry { #@test
    # Guard against docs/registry skew: the Configuration reference table
    # (docs/structured_output.md) and the traceback style table
    # (docs/technical_reference.md) advertise defaults that must match what
    # bu_config_register records (e.g. classic->unicode, short->full).
    local docs_out="$DIR/../docs/structured_output.md"
    local docs_ref="$DIR/../docs/technical_reference.md"
    local mismatches=()
    local checked=0
    local line var doc_default trail

    # --- docs/structured_output.md Configuration reference table ---
    while IFS='|' read -r _ var doc_default trail
    do
        var=${var//[[:space:]]/}
        var=${var//\`/}
        [[ "$var" =~ ^BU_[A-Z0-9_]+$ ]] || continue
        # Only registered settings carry a registry default to compare against.
        [[ "${BU_CONFIG_PROPERTIES[$var,registered]:-}" == true ]] || continue

        doc_default=${doc_default//\`/}
        doc_default=${doc_default#"${doc_default%%[![:space:]]*}"}
        doc_default=${doc_default%"${doc_default##*[![:space:]]}"}
        [[ "$doc_default" == "*(empty)*" ]] && doc_default=

        checked=$((checked + 1))
        if [[ "${BU_CONFIG_PROPERTIES[$var,default]}" != "$doc_default" ]]
        then
            mismatches+=("$var docs=[$doc_default] registry=[${BU_CONFIG_PROPERTIES[$var,default]}]")
        fi
    done < "$docs_out"

    if ((${#mismatches[@]} > 0))
    then
        printf 'docs/registry default mismatch:\n'
        printf '  %s\n' "${mismatches[@]}"
        false
    fi

    # Must have actually parsed the registered settings this guard protects.
    if (( checked < 4 ))
    then
        printf 'guard parsed only %d registered settings\n' "$checked"
        false
    fi

    # --- docs/technical_reference.md traceback style table ---
    # Exactly one style row is annotated "(default)"; it must match the
    # registered BU_STACKTRACE_STYLE default.
    local documented_style=
    while IFS='|' read -r _ var doc_default trail
    do
        var=${var//[[:space:]]/}
        var=${var//\`/}
        [[ "$var" == short || "$var" == full ]] || continue
        [[ "$doc_default" == *"(default)"* ]] || continue
        documented_style=$var
    done < "$docs_ref"
    assert_equal "${BU_CONFIG_PROPERTIES[BU_STACKTRACE_STYLE,default]}" "$documented_style"

    # The documented BU_STACKTRACE_CONTEXT_LINES default must match the global.
    assert grep -q "(default \`${BU_STACKTRACE_CONTEXT_LINES}\`)" "$docs_ref"
}

function test_config_preset_completion_verbatim { #@test
    bu_config_register BU_TEST_PRESETS --presets alpha preset:explicit beta presets--
    __bu_config_completion_values BU_TEST_PRESETS
    assert_equal "${BU_RET[*]}" 'alpha preset:explicit beta'
    bu set-config BU_TEST_PRESETS "${BU_RET[0]}" >/dev/null
    assert_equal "$BU_TEST_PRESETS" alpha
    __bu_config_completion_values BU_TABLE_PAGER
    assert_equal "${BU_RET[*]}" 'less less-quit bat never'
    bu set-config BU_TABLE_PAGER "${BU_RET[0]}" >/dev/null
    assert_equal "$BU_TABLE_PAGER" less
}

# ===========================================================================
# File-backed enums (--enum-file, --enum-source) and settings validation
# ===========================================================================

# A refreshed enum file: header, generated section, hand-kept section
function __write_venue_file {
    cat > "$BATS_TEST_TMPDIR/venues.txt" <<'VENUES'
# Venues for BU_TEST_VENUE
# maintained by ops

# --- generated (old, 2026-01-01) ---
xnys
xnas
arcx   # trailing comment
# --- hand-kept ---
# a test venue
mytest
VENUES
}

function __list_venues {
    printf '%s\n' xnys bats xnas
}

function test_config_enum_file_register { #@test
    printf '%s\n' '# modes' '' 'fast:1' '  slow:2' '# off' 'auto' > "$BATS_TEST_TMPDIR/modes.txt"
    bu_config_register BU_TEST_MODE --enum-file "$BATS_TEST_TMPDIR/modes.txt"
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_MODE,enum]}" 'fast:1 slow:2 auto'
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_MODE,enum_file]}" "$BATS_TEST_TMPDIR/modes.txt"
    bu_config_validate_value BU_TEST_MODE slow
    assert_equal "$BU_RET" 2
    run bu_config_validate_value BU_TEST_MODE off
    assert_failure
    __bu_config_completion_values BU_TEST_MODE
    assert_equal "${BU_RET[*]}" 'fast slow auto'

    # Both sections count; markers and comments do not
    __write_venue_file
    bu_config_register BU_TEST_VENUE --enum-file "$BATS_TEST_TMPDIR/venues.txt" --enum-source __list_venues
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_VENUE,enum]}" 'xnys xnas arcx mytest'
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_VENUE,enum_source]}" __list_venues
}

function test_config_enum_file_registration_errors { #@test
    run bu_config_register BU_TEST_MODE --enum-file "$BATS_TEST_TMPDIR/missing.txt"
    assert_failure
    assert_output --partial 'BU_TEST_MODE'
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_MODE,registered]:-}" ''
    printf 'a\n' > "$BATS_TEST_TMPDIR/modes.txt"
    run bu_config_register BU_TEST_MODE --enum a b enum-- --enum-file "$BATS_TEST_TMPDIR/modes.txt"
    assert_failure
    run bu_config_register BU_TEST_MODE --enum-source __list_venues
    assert_failure
    # A missing file with a source only warns: update-config-enum creates it
    bu_config_register BU_TEST_VENUE --enum-file "$BATS_TEST_TMPDIR/new.txt" --enum-source __list_venues 2>/dev/null
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_VENUE,registered]}" true
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_VENUE,enum]:-}" ''
}

function test_config_refresh_enum_file_dry_run { #@test
    __write_venue_file
    bu_config_register BU_TEST_VENUE --enum-file "$BATS_TEST_TMPDIR/venues.txt" --enum-source __list_venues
    local before out
    before=$(cat "$BATS_TEST_TMPDIR/venues.txt")
    bu_config_refresh_enum_file BU_TEST_VENUE > "$BATS_TEST_TMPDIR/out"
    out=$(cut -f3- "$BATS_TEST_TMPDIR/out")
    assert_equal "$out" $'added\tbats\twould-write\nremoved\tarcx\twould-write\nsummary\t3 generated, 1 hand-kept, +1 -1\twould-write'
    assert_equal "$(cut -f1,2 "$BATS_TEST_TMPDIR/out" | sort -u)" "BU_TEST_VENUE"$'\t'"$BATS_TEST_TMPDIR/venues.txt"
    assert_equal "$(cat "$BATS_TEST_TMPDIR/venues.txt")" "$before"
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_VENUE,enum]}" 'xnys xnas arcx mytest'
}

function test_config_refresh_enum_file_execute { #@test
    __write_venue_file
    bu_config_register BU_TEST_VENUE --enum-file "$BATS_TEST_TMPDIR/venues.txt" --enum-source __list_venues
    local out today
    printf -v today '%(%Y-%m-%d)T' -1
    bu_config_refresh_enum_file BU_TEST_VENUE --execute > "$BATS_TEST_TMPDIR/out"
    assert_equal "$(cut -f5 "$BATS_TEST_TMPDIR/out" | sort -u)" written
    assert_equal "$(cat "$BATS_TEST_TMPDIR/venues.txt")" "# Venues for BU_TEST_VENUE
# maintained by ops

# --- generated (__list_venues, $today) ---
xnys
bats
xnas

# --- hand-kept ---
# a test venue
mytest"
    # Live enum updated in this shell
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_VENUE,enum]}" 'xnys bats xnas mytest'
    # Nothing left to do: unchanged, file not rewritten
    out=$(bu_config_refresh_enum_file BU_TEST_VENUE --execute | cut -f3-)
    assert_equal "$out" $'summary\t3 generated, 1 hand-kept, +0 -0\tunchanged'
}

function test_config_refresh_enum_file_without_markers { #@test
    printf '%s\n' '# venues' xnys arcx > "$BATS_TEST_TMPDIR/venues.txt"
    bu_config_register BU_TEST_VENUE --enum-file "$BATS_TEST_TMPDIR/venues.txt" --enum-source __list_venues
    local out
    out=$(bu_config_refresh_enum_file BU_TEST_VENUE --execute | cut -f3,4)
    assert_equal "$out" $'added\tbats\nadded\txnas\nremoved\tarcx\nsummary\t3 generated, 0 hand-kept, +2 -1'
    assert_equal "$(sed -n '1p;3p' "$BATS_TEST_TMPDIR/venues.txt")" $'# venues\n# --- generated (__list_venues, '"$(printf '%(%Y-%m-%d)T' -1)"') ---'
    assert grep -qx '# --- hand-kept ---' "$BATS_TEST_TMPDIR/venues.txt"
}

function test_config_refresh_enum_file_failing_source { #@test
    __write_venue_file
    bu_config_register BU_TEST_VENUE --enum-file "$BATS_TEST_TMPDIR/venues.txt" --enum-source 'false'
    local before
    before=$(cat "$BATS_TEST_TMPDIR/venues.txt")
    run bu_config_refresh_enum_file BU_TEST_VENUE --execute
    assert_failure
    bu_config_register BU_TEST_VENUE --enum-file "$BATS_TEST_TMPDIR/venues.txt" --enum-source 'true'
    run bu_config_refresh_enum_file BU_TEST_VENUE --execute
    assert_failure
    assert_equal "$(cat "$BATS_TEST_TMPDIR/venues.txt")" "$before"
    # No --enum-source
    run bu_config_refresh_enum_file BU_LOG_LVL
    assert_failure
}

function test_config_validate_settings { #@test
    bu_config_register BU_TEST_MODE --enum fast slow enum--
    bu_config_register BU_TEST_FLAG --bool
    local out
    BU_TEST_MODE=bogus
    BU_TEST_FLAG=
    BU_LOG_LVL=4
    run bu_config_validate_settings BU_TEST_MODE BU_TEST_FLAG BU_LOG_LVL BU_TEST_NOPE
    assert_failure
    assert_equal "$output" "BU_TEST_MODE	bogus	default	invalid	expected one of: fast slow
BU_TEST_FLAG		default	ok	not applicable (empty)
BU_LOG_LVL	4	shell	ok	stored form of err
BU_TEST_NOPE			invalid	not a registered setting"
    # Names and --allow sentinels pass
    BU_TEST_MODE=slow
    out=$(bu_config_validate_settings BU_TEST_MODE BU_LOG_LVL | cut -f4 | sort -u)
    assert_equal "$out" ok
    BU_TEST_MODE=auto
    run bu_config_validate_settings --allow none --allow auto BU_TEST_MODE
    assert_success
    assert_output $'BU_TEST_MODE\tauto\tdefault\tok\tnot applicable (allowed by --allow)'
    # No names: every setting with an enum or bool rule (hint-only ones skipped)
    bu_config_register BU_TEST_FREE --hint "free text"
    BU_TEST_FREE=anything
    out=$(bu_config_validate_settings | cut -f1)
    [[ $'\n'"$out"$'\n' == *$'\nBU_TEST_MODE\n'* && $'\n'"$out"$'\n' == *$'\nBU_LOG_LVL\n'* ]]
    [[ $'\n'"$out"$'\n' != *$'\nBU_TEST_FREE\n'* ]]
}

function test_config_require_valid { #@test
    bu_config_register BU_TEST_MODE --enum fast slow enum--
    BU_TEST_MODE=fast
    run bu_config_require_valid BU_TEST_MODE BU_LOG_LVL
    assert_success
    assert_output ''
    BU_TEST_MODE=bogus
    run bu_config_require_valid BU_TEST_MODE BU_TEST_NOPE
    assert_failure
    assert_output --partial "Invalid setting BU_TEST_MODE='bogus'"
    assert_output --partial 'expected one of: fast slow'
    assert_output --partial 'Invalid setting BU_TEST_NOPE: not a registered setting'
}

function test_config_validate_config_cmdlet { #@test
    bu_config_register BU_TEST_MODE --enum fast slow enum--
    BU_TEST_MODE=bogus
    run bu validate-config BU_TEST_MODE BU_LOG_LVL --format jsonl
    assert_failure
    assert_equal "$(jq -r '"\(.name) \(.status)"' <<<"$output")" $'BU_TEST_MODE invalid\nBU_LOG_LVL ok'
    run bu validate-config --invalid --format jsonl
    assert_failure
    assert_equal "$(jq -r .name <<<"$output")" BU_TEST_MODE
    run bu validate-config BU_TEST_MODE --allow bogus --format tsv
    assert_success
}

function test_config_update_config_enum_cmdlet { #@test
    __write_venue_file
    bu_config_register BU_TEST_VENUE --enum-file "$BATS_TEST_TMPDIR/venues.txt" --enum-source __list_venues
    local out
    out=$(bu update-config-enum --format jsonl | jq -r '"\(.kind) \(.value) \(.action)"')
    assert_equal "$out" $'added bats would-write\nremoved arcx would-write\nsummary 3 generated, 1 hand-kept, +1 -1 would-write'
    # In this shell, so --execute updates the live enum
    bu update-config-enum BU_TEST_VENUE --execute --format jsonl > /dev/null
    assert_equal "${BU_CONFIG_PROPERTIES[BU_TEST_VENUE,enum]}" 'xnys bats xnas mytest'
    run bu update-config-enum BU_LOG_LVL --format jsonl
    assert_failure
}
