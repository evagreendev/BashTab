#!/usr/bin/env -S bats --jobs 4

# gitshelf demo module — binary/library duality, re-activation guard,
# converter rejection, globals survival under set -e.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    ROOT="$DIR/.."
}

# Run shell code in a fresh `bash --norc` with a clean BashTab environment, so
# the activate scripts behave exactly as they would in a brand-new shell.
# $1 = shell code; inside, $1 = the BashTab repo root.
_fresh() {
    local code=$1
    env -i HOME="$HOME" PATH="/usr/local/bin:/usr/bin:/bin" TERM=dumb \
        BU_OUT_DIR="$BATS_TEST_TMPDIR/.bu" \
        bash --norc -c "$code" _ "$ROOT"
}

# ── Binary mode ────────────────────────────────────────────────────

function test_gitshelf_binary_activate_help_and_jsonl { #@test
    run _fresh '
        set -e
        root=$1
        source "$root/examples/gitshelf/activate" >/dev/null 2>&1
        [[ "$BU_TOP_LEVEL_MODULE" == gitshelf ]]
        [[ "$BU_USER_DEFINED_CLI_COMMAND_NAME" == shelf ]]
        [[ "$(type -t shelf)" == function ]]
        shelf get-repo --help 2>/dev/null | grep -q "SYNOPSIS"
        shelf get-repo --format jsonl 2>/dev/null | jq -e . >/dev/null
        echo OK
    '
    assert_success
    assert_output "OK"
}

# ── Library mode ───────────────────────────────────────────────────

function test_devbox_library_mode_consumes_gitshelf { #@test
    run _fresh '
        set -e
        root=$1
        source "$root/examples/devbox/activate" >/dev/null 2>&1
        [[ "$BU_TOP_LEVEL_MODULE" == devbox ]]
        [[ "$BU_USER_DEFINED_CLI_COMMAND_NAME" == devbox ]]
        devbox get-repo --format jsonl 2>/dev/null | jq -e . >/dev/null
        devbox get-env --format jsonl 2>/dev/null | jq -e . >/dev/null
        modules=$(bu get-module --format jsonl 2>/dev/null | jq -r .name)
        [[ "$modules" == *devbox* ]]
        [[ "$modules" == *gitshelf* ]]
        echo OK
    '
    assert_success
    assert_output "OK"
}

# ── Re-activation guard ────────────────────────────────────────────

function test_gitshelf_activate_inside_devbox_is_info_noop { #@test
    run _fresh '
        set -e
        root=$1
        source "$root/examples/devbox/activate" >/dev/null 2>&1
        out=$(source "$root/examples/gitshelf/activate" 2>&1)
        [[ "$BU_TOP_LEVEL_MODULE" == devbox ]]
        [[ "$out" == *"gitshelf already active under devbox"* ]]
        echo OK
    '
    assert_success
    assert_output "OK"
}

function test_gitshelf_activate_inside_foreign_shell_warns_noop { #@test
    run _fresh '
        set -e
        root=$1
        source "$root/activate" >/dev/null 2>&1
        before=$BU_TOP_LEVEL_MODULE
        out=$(source "$root/examples/gitshelf/activate" 2>&1)
        [[ "$BU_TOP_LEVEL_MODULE" == "$before" ]]
        [[ "$out" == *"was NOT activated"* ]]
        [[ "$BU_MODULE_LIST" != *"gitshelf:"* ]]
        echo OK
    '
    assert_success
    assert_output "OK"
}

# ── Converter rejects non-script files ─────────────────────────────

function test_gitshelf_converter_rejects_non_script_files { #@test
    local planted="$ROOT/examples/gitshelf/commands/shelf.json"
    cp "$ROOT/examples/gitshelf/config/shelf.json" "$planted"
    run _fresh '
        set -e
        root=$1
        source "$root/examples/gitshelf/activate" >/dev/null 2>&1
        if [[ -n "${BU_COMMANDS[shelf]:-}" ]]; then echo REGISTERED; else echo REJECTED; fi
    '
    rm -f "$planted"
    assert_success
    assert_output "REJECTED"
}

# ── Globals survive and set -e safety ──────────────────────────────

function test_gitshelf_globals_survive_under_set_e { #@test
    run _fresh '
        set -e
        root=$1
        source "$root/examples/gitshelf/activate" >/dev/null 2>&1
        [[ "$GITSHELF_DIR" == *"/examples/gitshelf" ]]
        [[ -n "$GITSHELF_CONFIG_FILE" ]]
        [[ "${GITSHELF_STATE[version]}" == 0.1.0 ]]
        [[ -n "${!GITSHELF_STATE[@]}" ]]
        echo OK
    '
    assert_success
    assert_output "OK"
}

# ── Top-level activate --example delegation ────────────────────────

function test_activate_example_option_delegates { #@test
    run _fresh '
        set -e
        root=$1
        source "$root/activate" --example gitshelf >/dev/null 2>&1
        [[ "$BU_TOP_LEVEL_MODULE" == gitshelf ]]
        [[ "$BU_USER_DEFINED_CLI_COMMAND_NAME" == shelf ]]
        shelf get-repo --format jsonl 2>/dev/null | jq -e . >/dev/null
        echo OK
    '
    assert_success
    assert_output "OK"
}
