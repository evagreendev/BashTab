#!/usr/bin/env -S bats --jobs 16

# Unit tests for lib/core/bu_core_context.sh — origin tracking (write side)
# and consumption logging (read side) — plus the bu get-context-usage query
# builtin.
#
# Every helper test runs in a bare `bash -euo pipefail` subshell (bats has its
# own DEBUG-trap machinery; the helpers must prove errexit/nounset safety),
# with bu_env_is_in_autocomplete stubbed and BU_OUT_DIR pointed at a test
# tmpdir.  Only the CLI-level test sources the full entrypoint.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    MODULE="$DIR/../lib/core/bu_core_context.sh"

    # Common fixture: a vars file with known, stable line numbers.
    cat > "$BATS_TEST_TMPDIR/vars.sh" <<'EOF'
MY_COLOUR=blue
MY_COLOUR=red
OTHER_VAR=keep
lower_var=nope
EOF
    VARS_FIXTURE="$BATS_TEST_TMPDIR/vars.sh"
}

# ===========================================================================
# Write side — origin tracking
# ===========================================================================

function test_var_origin_exact_line_last_write_wins { #@test
    local script="$BATS_TEST_TMPDIR/t1.sh"
    cat > "$script" <<'EOF'
source "$1"
bu_var_origin_enable --reset
source "$2"
bu_var_origin_disable
printf 'MY_COLOUR=%s\n' "${BU_VARIABLE_ORIGIN[MY_COLOUR]:-UNTRACKED}"
printf 'OTHER_VAR=%s\n' "${BU_VARIABLE_ORIGIN[OTHER_VAR]:-UNTRACKED}"
EOF
    run bash -euo pipefail "$script" "$MODULE" "$VARS_FIXTURE"
    assert_success
    # Last write wins: MY_COLOUR reassigned on line 2; OTHER_VAR on line 3.
    assert_line --index 0 "MY_COLOUR=$VARS_FIXTURE:2"
    assert_line --index 1 "OTHER_VAR=$VARS_FIXTURE:3"
}

function test_var_origin_lowercase_untracked { #@test
    local script="$BATS_TEST_TMPDIR/t2.sh"
    cat > "$script" <<'EOF'
source "$1"
bu_var_origin_enable --reset
source "$2"
bu_var_origin_disable
printf 'lower_var=%s\n' "${BU_VARIABLE_ORIGIN[lower_var]:-UNTRACKED}"
EOF
    run bash -euo pipefail "$script" "$MODULE" "$VARS_FIXTURE"
    assert_success
    assert_output "lower_var=UNTRACKED"
}

function test_var_origin_outside_window_untracked { #@test
    local script="$BATS_TEST_TMPDIR/t3.sh"
    cat > "$script" <<'EOF'
source "$1"
OUTSIDE_BEFORE=1
bu_var_origin_enable --reset
INSIDE=2
bu_var_origin_disable
OUTSIDE_AFTER=3
printf 'OUTSIDE_BEFORE=%s\n' "${BU_VARIABLE_ORIGIN[OUTSIDE_BEFORE]:-UNTRACKED}"
printf 'INSIDE=%s\n' "${BU_VARIABLE_ORIGIN[INSIDE]:-UNTRACKED}"
printf 'OUTSIDE_AFTER=%s\n' "${BU_VARIABLE_ORIGIN[OUTSIDE_AFTER]:-UNTRACKED}"
EOF
    run bash -euo pipefail "$script" "$MODULE"
    assert_success
    assert_line --index 0 "OUTSIDE_BEFORE=UNTRACKED"
    refute_line --index 1 "INSIDE=UNTRACKED"
    assert_line --index 2 "OUTSIDE_AFTER=UNTRACKED"
}

function test_var_origin_accumulate_vs_reset { #@test
    local script="$BATS_TEST_TMPDIR/t4.sh"
    cat > "$script" <<'EOF'
source "$1"
# Window 1 (no reset): accumulates.
bu_var_origin_enable
FIRST=1
bu_var_origin_disable
# Window 2 (no reset): accumulates alongside the first.
bu_var_origin_enable
SECOND=2
bu_var_origin_disable
printf 'FIRST=%s\n' "${BU_VARIABLE_ORIGIN[FIRST]:-UNTRACKED}"
printf 'SECOND=%s\n' "${BU_VARIABLE_ORIGIN[SECOND]:-UNTRACKED}"
# Window 3 with --reset: clears, then tracks only the new write.
bu_var_origin_enable --reset
THIRD=3
bu_var_origin_disable
printf 'FIRST_after_reset=%s\n' "${BU_VARIABLE_ORIGIN[FIRST]:-UNTRACKED}"
printf 'THIRD=%s\n' "${BU_VARIABLE_ORIGIN[THIRD]:-UNTRACKED}"
EOF
    run bash -euo pipefail "$script" "$MODULE"
    assert_success
    refute_line --index 0 "FIRST=UNTRACKED"
    refute_line --index 1 "SECOND=UNTRACKED"
    assert_line --index 2 "FIRST_after_reset=UNTRACKED"
    refute_line --index 3 "THIRD=UNTRACKED"
}

function test_var_origin_restores_prior_trap_and_functrace { #@test
    local script="$BATS_TEST_TMPDIR/t5.sh"
    cat > "$script" <<'EOF'
source "$1"
trap 'echo ORIGINAL >&2' DEBUG
set -o functrace
bu_var_origin_enable
source "$2"
bu_var_origin_disable
shopt -qo functrace && echo "functrace=on" || echo "functrace=off"
trap -p DEBUG
EOF
    run bash -euo pipefail "$script" "$MODULE" "$VARS_FIXTURE"
    assert_success
    assert_output --partial "functrace=on"
    assert_output --partial "trap -- 'echo ORIGINAL >&2' DEBUG"
}

function test_var_origin_functrace_off_restored { #@test
    local script="$BATS_TEST_TMPDIR/t5b.sh"
    cat > "$script" <<'EOF'
source "$1"
bu_var_origin_enable
source "$2"
bu_var_origin_disable
shopt -qo functrace && echo "functrace=on" || echo "functrace=off"
trap -p DEBUG
EOF
    run bash -euo pipefail "$script" "$MODULE" "$VARS_FIXTURE"
    assert_success
    assert_line --index 0 "functrace=off"
    # No prior trap and no leak: `trap -p DEBUG` prints nothing after disable.
    assert_equal "${#lines[@]}" 1
}

function test_var_origin_enable_while_armed_noop { #@test
    local script="$BATS_TEST_TMPDIR/t6.sh"
    cat > "$script" <<'EOF'
source "$1"
bu_var_origin_enable --reset
AAA=1
# No-op re-enable (never nests).
bu_var_origin_enable
# --reset applies even while armed (clears, but does not re-arm/nest).
bu_var_origin_enable --reset
AAA=2
bu_var_origin_disable
printf 'AAA=%s\n' "${BU_VARIABLE_ORIGIN[AAA]:-UNTRACKED}"
if [[ -z "$(trap -p DEBUG)" ]]; then echo "trap_cleared"; else echo "trap_STILL_SET"; fi
EOF
    run bash -euo pipefail "$script" "$MODULE"
    assert_success
    # AAA was re-tracked after --reset (last write at AAA=2), proving the map
    # was cleared and the trap remained armed.
    refute_line --index 0 "AAA=UNTRACKED"
    # A single disable fully disarmed — no nested trap survived.
    assert_line --index 1 "trap_cleared"
}

function test_var_origin_prefix_regex { #@test
    local script="$BATS_TEST_TMPDIR/t7.sh"
    cat > "$script" <<'EOF'
source "$1"
bu_var_origin_enable --reset --prefix-regex 'MY_[A-Z0-9_]*'
MY_TRACKED=1
OTHER_THING=2
MY_TRACKED2=3
bu_var_origin_disable
printf 'MY_TRACKED=%s\n' "${BU_VARIABLE_ORIGIN[MY_TRACKED]:-UNTRACKED}"
printf 'OTHER_THING=%s\n' "${BU_VARIABLE_ORIGIN[OTHER_THING]:-UNTRACKED}"
printf 'MY_TRACKED2=%s\n' "${BU_VARIABLE_ORIGIN[MY_TRACKED2]:-UNTRACKED}"
EOF
    run bash -euo pipefail "$script" "$MODULE"
    assert_success
    refute_line --index 0 "MY_TRACKED=UNTRACKED"
    assert_line --index 1 "OTHER_THING=UNTRACKED"
    refute_line --index 2 "MY_TRACKED2=UNTRACKED"
}

function test_var_origin_relative_source_absolutized { #@test
    local script="$BATS_TEST_TMPDIR/t8.sh"
    cat > "$script" <<'EOF'
source "$1"
cd "$2"
bu_var_origin_enable --reset
source ./vars.sh
bu_var_origin_disable
printf 'MY_COLOUR=%s\n' "${BU_VARIABLE_ORIGIN[MY_COLOUR]:-UNTRACKED}"
EOF
    run bash -euo pipefail "$script" "$MODULE" "$BATS_TEST_TMPDIR"
    assert_success
    # Relative ./vars.sh is absolutized against PWD; last write at line 2.
    assert_line --index 0 "MY_COLOUR=$BATS_TEST_TMPDIR/./vars.sh:2"
}

# ===========================================================================
# Read side — consumption logging
# ===========================================================================

function test_context_default_context_wins { #@test
    local out_dir="$BATS_TEST_TMPDIR/ctx1"
    mkdir -p "$out_dir"
    local script="$BATS_TEST_TMPDIR/r1.sh"
    cat > "$script" <<'EOF'
source "$1"
export BU_OUT_DIR="$2"
bu_env_is_in_autocomplete() { return 1; }
demo() { local colour=; bu_context_default colour MY_APP_COLO; echo "COLOUR=[$colour]"; }
MY_APP_COLO=blue
demo
echo "---record---"
cat "$BU_OUT_DIR"/context/*.jsonl
EOF
    run bash -euo pipefail "$script" "$MODULE" "$out_dir"
    assert_success
    # stderr wording: local=value <- CONTEXT_VAR
    assert_output --partial "[ctx] colour=blue <- MY_APP_COLO"
    assert_output --partial "COLOUR=[blue]"
    # record source=context, value=ambient
    assert_output --partial '"var":"MY_APP_COLO","value":"blue","local":"colour","source":"context"'
}

function test_context_default_flag_wins { #@test
    local out_dir="$BATS_TEST_TMPDIR/ctx2"
    mkdir -p "$out_dir"
    local script="$BATS_TEST_TMPDIR/r2.sh"
    cat > "$script" <<'EOF'
source "$1"
export BU_OUT_DIR="$2"
bu_env_is_in_autocomplete() { return 1; }
demo() { local colour=explicit; bu_context_default colour MY_APP_COLO; echo "COLOUR=[$colour]"; }
MY_APP_COLO=blue
demo
echo "---record---"
cat "$BU_OUT_DIR"/context/*.jsonl
EOF
    run bash -euo pipefail "$script" "$MODULE" "$out_dir"
    assert_success
    # stderr wording: local=flagvalue <- flag (CONTEXT_VAR overridden)
    assert_output --partial "[ctx] colour=explicit <- flag (MY_APP_COLO overridden)"
    assert_output --partial "COLOUR=[explicit]"
    # record: value is the AMBIENT value; source=flag
    assert_output --partial '"var":"MY_APP_COLO","value":"blue","local":"colour","source":"flag"'
}

function test_context_default_unset_var { #@test
    local out_dir="$BATS_TEST_TMPDIR/ctx3"
    mkdir -p "$out_dir"
    local script="$BATS_TEST_TMPDIR/r3.sh"
    cat > "$script" <<'EOF'
source "$1"
export BU_OUT_DIR="$2"
bu_env_is_in_autocomplete() { return 1; }
demo() { local colour=; bu_context_default colour MY_UNSET_VAR; echo "COLOUR=[$colour]"; }
demo
echo "---record---"
cat "$BU_OUT_DIR"/context/*.jsonl
EOF
    run bash -euo pipefail "$script" "$MODULE" "$out_dir"
    assert_success
    assert_output --partial "[ctx] colour= <- MY_UNSET_VAR"
    assert_output --partial "COLOUR=[]"
    # empty value is logged, source=context
    assert_output --partial '"value":"","local":"colour","source":"context"'
}

function test_context_use_bu_ret_and_source_read { #@test
    local out_dir="$BATS_TEST_TMPDIR/ctx4"
    mkdir -p "$out_dir"
    local script="$BATS_TEST_TMPDIR/r4.sh"
    cat > "$script" <<'EOF'
source "$1"
export BU_OUT_DIR="$2"
bu_env_is_in_autocomplete() { return 1; }
MY_APP_COLO=blue
bu_context_use MY_APP_COLO
echo "RET=[${BU_RET[0]:-}]"
echo "---record---"
cat "$BU_OUT_DIR"/context/*.jsonl
EOF
    run bash -euo pipefail "$script" "$MODULE" "$out_dir"
    assert_success
    assert_output --partial "RET=[blue]"
    assert_output --partial '"value":"blue","local":"","source":"read"'
}

function test_context_autocomplete_silence { #@test
    local out_dir="$BATS_TEST_TMPDIR/ctx5"
    mkdir -p "$out_dir"
    local script="$BATS_TEST_TMPDIR/r5.sh"
    cat > "$script" <<'EOF'
source "$1"
export BU_OUT_DIR="$2"
bu_env_is_in_autocomplete() { return 0; }
demo() { local colour=; bu_context_default colour MY_APP_COLO; }
MY_APP_COLO=blue
demo
if [[ -d "$BU_OUT_DIR/context" ]]; then echo "RECORD_DIR_EXISTS"; else echo "NO_RECORD_DIR"; fi
EOF
    run bash -euo pipefail "$script" "$MODULE" "$out_dir"
    assert_success
    refute_output --partial "[ctx]"
    assert_output "NO_RECORD_DIR"
}

function test_context_json_validity { #@test
    local out_dir="$BATS_TEST_TMPDIR/ctx6"
    mkdir -p "$out_dir"
    local script="$BATS_TEST_TMPDIR/r6.sh"
    cat > "$script" <<'EOF'
source "$1"
export BU_OUT_DIR="$2"
bu_env_is_in_autocomplete() { return 1; }
MY_SPECIAL_VAR='has "quotes" and \backslash and
a newline	and a tab'
bu_context_use MY_SPECIAL_VAR
if command -v jq >/dev/null; then
    jq -e . "$BU_OUT_DIR"/context/*.jsonl >/dev/null && echo "JSON_VALID"
else
    echo "JQ_UNAVAILABLE"
fi
EOF
    run bash -euo pipefail "$script" "$MODULE" "$out_dir"
    assert_success
    assert_output --partial "JSON_VALID"
}

function test_context_unwritable_out_dir { #@test
    # A FILE in place of the directory makes mkdir -p fail everywhere.
    local blocker="$BATS_TEST_TMPDIR/blocker"
    touch "$blocker"
    local script="$BATS_TEST_TMPDIR/r7.sh"
    cat > "$script" <<'EOF'
source "$1"
export BU_OUT_DIR="$2"
bu_env_is_in_autocomplete() { return 1; }
demo() { local colour=; bu_context_default colour MY_APP_COLO; }
MY_APP_COLO=blue
demo
echo "REACHED"
EOF
    run bash -euo pipefail "$script" "$MODULE" "$blocker"
    assert_success
    # stderr line still present even though the record path is unwritable
    assert_output --partial "[ctx] colour=blue <- MY_APP_COLO"
    assert_output --partial "REACHED"
}

# ===========================================================================
# Query builtin (CLI level)
# ===========================================================================

function test_cli_get_context_usage { #@test
    run bash -c '
        export BU_TOP_LEVEL_MODULE=bashtab
        export BU_OUT_DIR=$(mktemp -d)
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        mkdir -p "$BU_OUT_DIR/context"
        printf "%s\n" "{\"ts\":1,\"command\":\"testcmd\",\"var\":\"MY_VAR\",\"value\":\"x\",\"local\":\"v\",\"source\":\"context\",\"origin\":\"f:1\"}" > "$BU_OUT_DIR/context/2026-01-01.jsonl"
        printf "%s\n" "{\"ts\":2,\"command\":\"other\",\"var\":\"MY_VAR\",\"value\":\"y\",\"local\":\"\",\"source\":\"read\",\"origin\":\"\"}" > "$BU_OUT_DIR/context/2026-01-02.jsonl"
        bu get-context-usage --format jsonl
    ' _ "$DIR/.."
    assert_success
    assert_line --index 0 '{"ts":1,"command":"testcmd","var":"MY_VAR","value":"x","local":"v","source":"context","origin":"f:1"}'
    assert_line --index 1 '{"ts":2,"command":"other","var":"MY_VAR","value":"y","local":"","source":"read","origin":""}'
}

function test_cli_get_context_usage_empty_success { #@test
    run bash -c '
        export BU_TOP_LEVEL_MODULE=bashtab
        export BU_OUT_DIR=$(mktemp -d)
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        bu get-context-usage --format jsonl
    ' _ "$DIR/.."
    assert_success
    assert_equal "$output" ""
}
