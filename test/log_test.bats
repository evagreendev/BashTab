#!/usr/bin/env -S bats --jobs 16

# Tests for the logging helpers in lib/core/bu_core_base.sh: `-i|--idx`
# attribution in bu_log_success / bu_log_trace, bu_log_err_usage, and the
# level-gated bu_log_cmd_* command loggers.
#
# Each test writes a fixture `my-tool.sh` and sources it from a clean shell
# with the entrypoint loaded and `set -eu` on. TERM=dumb degrades all tput
# codes to empty so assertions see plain text.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    TOOL="$BATS_TEST_TMPDIR/my-tool.sh"
}

# Write the fixture script from stdin.
function write_tool {
    cat > "$TOOL"
}

# Run the fixture with stdout and stderr merged.
# Args: extra environment assignments (e.g. BU_LOG_LVL=0)
function run_tool {
    run env -i HOME="$HOME" PATH="$PATH" TERM=dumb BU_OUT_DIR="$BATS_TEST_TMPDIR/out" "$@" \
        bash -c 'source "$1"/bu_entrypoint.sh >/dev/null 2>&1; set -eu; source "$2"' \
        _ "$DIR/.." "$TOOL"
}

# MARK: -i handling in bu_log_success / bu_log_trace

function test_log_success_idx_attributes_to_caller { #@test
    write_tool <<'EOF'
helper() {
    bu_log_success -i 1 hello
}
tool_main() {
    helper
}
tool_main
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    assert_output "SUCCESS my-tool.sh:5[tool_main] hello"
}

function test_log_trace_idx_attributes_to_caller { #@test
    write_tool <<'EOF'
helper() {
    bu_log_trace -i 1 hello
}
tool_main() {
    helper
}
tool_main
EOF
    run_tool BU_LOG_LVL=0
    assert_success
    assert_output --regexp '^TRACE   my-tool\.sh:5\[tool_main\] \[[0-9.]*\] hello$'
    refute_output --partial '-i 1'
}

function test_log_success_and_trace_no_args_under_set_u { #@test
    write_tool <<'EOF'
tool_main() {
    bu_log_success
    bu_log_trace
    echo done
}
tool_main
EOF
    run_tool BU_LOG_LVL=0
    assert_success
    assert_line --index 0 "SUCCESS my-tool.sh:2[tool_main] "
    assert_line --index 1 --regexp '^TRACE   my-tool\.sh:3\[tool_main\] \[[0-9.]*\] $'
    assert_line --index 2 "done"
}

# MARK: bu_log_err_usage

function test_log_err_usage_prints_error_and_hint { #@test
    write_tool <<'EOF'
tool_main() {
    bu_log_err_usage "Missing --name"
}
tool_main
EOF
    run_tool
    assert_success
    assert_line --index 0 "ERR     my-tool.sh:2[tool_main] Missing --name"
    assert_line --index 1 "hint:  bu my-tool --help"
    assert_equal "${#lines[@]}" 2
}

function test_log_err_usage_custom_cli_name { #@test
    write_tool <<'EOF'
tool_main() {
    bu_log_err_usage "Missing --name"
}
tool_main
EOF
    run_tool BU_USER_DEFINED_CLI_COMMAND_NAME=mycli
    assert_success
    assert_line --index 1 "hint:  mycli my-tool --help"
}

function test_log_err_usage_idx_attributes_to_caller { #@test
    write_tool <<'EOF'
helper() {
    bu_log_err_usage -i 1 "Missing --name"
}
tool_main() {
    helper
}
tool_main
EOF
    run_tool
    assert_success
    assert_line --index 0 "ERR     my-tool.sh:5[tool_main] Missing --name"
    assert_line --index 1 "hint:  bu my-tool --help"
}

function test_log_err_usage_silenced { #@test
    write_tool <<'EOF'
tool_main() {
    bu_log_err_usage "Missing --name"
}
tool_main
EOF
    run_tool BU_LOG_LVL=99
    assert_success
    assert_output ""
}

# MARK: bu_log_cmd_* output

function test_log_cmd_info_logs_quoted_argv_then_output { #@test
    write_tool <<'EOF'
tool_main() {
    bu_log_cmd_info fn "a b" c
}
fn() { echo "fn-output $#"; }
tool_main
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    assert_line --index 0 'INFO    my-tool.sh:2[tool_main] fn a\ b c'
    assert_line --index 1 "fn-output 2"
    assert_equal "${#lines[@]}" 2
}

function test_log_cmd_info_output_goes_to_stderr { #@test
    write_tool <<'EOF'
tool_main() {
    bu_log_cmd_info echo x 2>/dev/null
}
tool_main
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    assert_output ""
}

function test_log_cmd_echo_printf_skip_argv_line { #@test
    write_tool <<'EOF'
tool_main() {
    bu_log_cmd_info echo hello
    bu_log_cmd_warn printf '%s\n' world
}
tool_main
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    assert_line --index 0 "hello"
    assert_line --index 1 "world"
    assert_equal "${#lines[@]}" 2
}

function test_log_cmd_printf_q_gets_newline { #@test
    write_tool <<'EOF'
tool_main() {
    bu_log_cmd_info printf '%q ' a 'b c'
    echo next
}
tool_main
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    assert_line --index 0 'a b\ c '
    assert_line --index 1 "next"
}

# MARK: bu_log_cmd_* level gating

function test_log_cmd_info_suppressed_does_not_run { #@test
    write_tool <<EOF
tool_main() {
    bu_log_cmd_info touch "$BATS_TEST_TMPDIR/marker"
    echo "rc=\$?"
}
tool_main
EOF
    run_tool BU_LOG_LVL=4
    assert_success
    assert_output "rc=0"
    [[ ! -e "$BATS_TEST_TMPDIR/marker" ]]
}

function test_log_cmd_info_enabled_runs { #@test
    write_tool <<EOF
tool_main() {
    bu_log_cmd_info touch "$BATS_TEST_TMPDIR/marker"
}
tool_main
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    [[ -e "$BATS_TEST_TMPDIR/marker" ]]
}

function test_log_cmd_err_runs_at_err_level { #@test
    write_tool <<EOF
tool_main() {
    bu_log_cmd_err touch "$BATS_TEST_TMPDIR/marker"
}
tool_main
EOF
    run_tool BU_LOG_LVL=4
    assert_success
    assert_output --partial "ERR     my-tool.sh:2[tool_main] touch "
    [[ -e "$BATS_TEST_TMPDIR/marker" ]]
}

function test_log_cmd_debug_suppressed_at_default_level { #@test
    write_tool <<EOF
tool_main() {
    bu_log_cmd_debug touch "$BATS_TEST_TMPDIR/marker"
}
tool_main
EOF
    run_tool
    assert_success
    assert_output ""
    [[ ! -e "$BATS_TEST_TMPDIR/marker" ]]
}

# MARK: bu_log_cmd_* exit codes

function test_log_cmd_failure_reports_and_returns_1 { #@test
    write_tool <<'EOF'
tool_main() {
    local rc=0
    bu_log_cmd_info false || rc=$?
    echo "rc=$rc"
}
tool_main
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    assert_line --index 0 "INFO    my-tool.sh:3[tool_main] false"
    assert_line --index 1 "(cmd failed)"
    assert_line --index 2 "rc=1"
}

function test_log_cmd_failure_aborts_under_set_e { #@test
    write_tool <<'EOF'
bu_log_cmd_warn false
echo "not reached"
EOF
    run_tool
    assert_failure
    assert_output --partial "(cmd failed)"
    refute_output --partial "not reached"
}

function test_log_cmd_ignore_exit_code { #@test
    write_tool <<'EOF'
tool_main() {
    bu_log_cmd_info --ignore-exit-code false
    echo "rc=$?"
}
tool_main
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    assert_line --index 0 "INFO    my-tool.sh:2[tool_main] false"
    assert_line --index 1 "rc=0"
    refute_output --partial "(cmd failed)"
}

# MARK: bu_log_cmd_* -i handling

function test_log_cmd_idx_attributes_to_caller { #@test
    write_tool <<'EOF'
helper() {
    bu_log_cmd_info -i 1 true
}
tool_main() {
    helper
}
tool_main
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    assert_output "INFO    my-tool.sh:5[tool_main] true"
}

function test_log_cmd_options_in_either_order { #@test
    write_tool <<'EOF'
helper() {
    bu_log_cmd_info --ignore-exit-code -i 1 false
    bu_log_cmd_info -i 1 --ignore-exit-code false
}
tool_main() {
    helper
}
tool_main
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    assert_line --index 0 "INFO    my-tool.sh:6[tool_main] false"
    assert_line --index 1 "INFO    my-tool.sh:6[tool_main] false"
    refute_output --partial "(cmd failed)"
}

function test_log_cmd_no_command_returns_0 { #@test
    write_tool <<'EOF'
bu_log_cmd_info
bu_log_cmd_info --ignore-exit-code -i 1
echo done
EOF
    run_tool BU_LOG_LVL=2
    assert_success
    assert_output "done"
}
