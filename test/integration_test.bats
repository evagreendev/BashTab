#!/usr/bin/env -S bats --jobs 16
#
# Integration tests: cold and warm activation, command availability,
# and module registration.
#

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"

    TEST_MODULE_DIR=$(mktemp -d /tmp/bashtab-integration-test.XXXXXX)
    mkdir -p "$TEST_MODULE_DIR"/commands

    cat > "$TEST_MODULE_DIR"/test_preinit.sh << 'PREINIT'
#!/usr/bin/env bash
source "$BU_NULL"
bu_pushd_current "$BASH_SOURCE"
bu import-environment +i -c ./commands -ns prefix
bu_popd_silent
PREINIT

    # Clean all possible cache locations (USER may be empty in subshells)
    rm -f /tmp/bu/user/cache/commands-ittest.cache 2>/dev/null
    rm -f /tmp/bu/cache/commands-ittest.cache 2>/dev/null
}

teardown() {
    rm -rf "$TEST_MODULE_DIR" 2>/dev/null || true
    rm -f /tmp/bu/user/cache/commands-ittest.cache 2>/dev/null
    rm -f /tmp/bu/cache/commands-ittest.cache 2>/dev/null
}

# ── No top-level module (backward compat) ──────────────────────────────

function test_no_top_level_module_works { #@test
    run bash -c '
        unset BU_TOP_LEVEL_MODULE
        export BU_MODULE_LIST=
        source "$1"/bu_entrypoint.sh > /dev/null 2>&1
        echo "COUNT=${#BU_COMMANDS[@]}"
        echo "IMPORT_ENV=$([[ -n ${BU_COMMANDS[import-environment]:-} ]] && echo FOUND || echo MISSING)"
    ' _ "$DIR"/..
    assert_success
    count_line=$(echo "$output" | grep "^COUNT=")
    count=${count_line#COUNT=}
    [[ $count -gt 50 ]]
    assert_line --partial "IMPORT_ENV=FOUND"
}

# ── Cold activation (first time) ───────────────────────────────────────

function test_cold_activation_commands_available { #@test
    run bash -c '
        export BU_TOP_LEVEL_MODULE=ittest
        export BU_MODULE_LIST="ittest:0.1.0:$1/test_preinit.sh;"
        source "$2"/bu_entrypoint.sh > /dev/null 2>&1
        echo "COUNT=${#BU_COMMANDS[@]}"
        echo "IMPORT_ENV=$([[ -n ${BU_COMMANDS[import-environment]:-} ]] && echo FOUND || echo MISSING)"
        echo "REGISTRY=${BU_MODULE_REGISTRY[ittest]:-NOT_FOUND}"
    ' _ "$TEST_MODULE_DIR" "$DIR"/..
    assert_success
    count_line=$(echo "$output" | grep "^COUNT=")
    count=${count_line#COUNT=}
    [[ $count -gt 50 ]]
    assert_line --partial "IMPORT_ENV=FOUND"
    refute_line --partial "REGISTRY=NOT_FOUND"
}

# ── Warm activation (cache hit, commands rebuilt from find) ────────────

function test_warm_activation_commands_available { #@test
    # First run: populate and save the cache
    run bash -c '
        export BU_TOP_LEVEL_MODULE=ittest
        export BU_MODULE_LIST="ittest:0.1.0:$1/test_preinit.sh;"
        source "$2"/bu_entrypoint.sh > /dev/null 2>&1
        bu_mark_load_complete > /dev/null 2>&1
        echo "CACHE_DIR=$BU_CACHE_DIR"
    ' _ "$TEST_MODULE_DIR" "$DIR"/..
    assert_success

    # Extract cache dir and check file exists
    cache_dir_line=$(echo "$output" | grep "^CACHE_DIR=")
    CACHE_DIR=${cache_dir_line#CACHE_DIR=}
    CACHE_FILE="$CACHE_DIR/commands-ittest.cache"
    [[ -f "$CACHE_FILE" ]]

    # Second run: should hit cache and rebuild commands from find.
    # The key thing is that commands (especially import-environment) work.
    run bash -c '
        export BU_TOP_LEVEL_MODULE=ittest
        export BU_MODULE_LIST="ittest:0.1.0:$1/test_preinit.sh;"
        source "$2"/bu_entrypoint.sh > /dev/null 2>&1
        echo "COUNT=${#BU_COMMANDS[@]}"
        echo "IMPORT_ENV=$([[ -n ${BU_COMMANDS[import-environment]:-} ]] && echo FOUND || echo MISSING)"
    ' _ "$TEST_MODULE_DIR" "$DIR"/..
    assert_success
    count_line=$(echo "$output" | grep "^COUNT=")
    count=${count_line#COUNT=}
    [[ $count -gt 50 ]]
    assert_line --partial "IMPORT_ENV=FOUND"
}

# ── bu set-location finds the module root ──────────────────────────────

function test_set_location_module { #@test
    run bash -c '
        export BU_TOP_LEVEL_MODULE=ittest
        export BU_MODULE_LIST="ittest:0.1.0:$1/test_preinit.sh;"
        source "$2"/bu_entrypoint.sh > /dev/null 2>&1
        bu set-location --module > /dev/null 2>&1
        echo "PWD=$PWD"
    ' _ "$TEST_MODULE_DIR" "$DIR"/..
    assert_success
    assert_line "PWD=$TEST_MODULE_DIR"
}

function test_activation_no_find_warnings { #@test
    # GNU find warns when positional options like -maxdepth appear after
    # non-positional ones like -type. Activation must not leak these.
    run bash -c '
        export BU_TOP_LEVEL_MODULE=ittest
        export BU_MODULE_LIST="ittest:0.1.0:$1/test_preinit.sh;"
        source "$2"/bu_entrypoint.sh
    ' _ "$TEST_MODULE_DIR" "$DIR"/..
    assert_success
    # GNU find warning: "warning: you have used the -maxdepth option after a
    # non-option argument -type, but options are not positional"
    refute_output --partial "maxdepth"
    refute_output --partial "warning"
}
