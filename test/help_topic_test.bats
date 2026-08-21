#!/usr/bin/env -S bats --jobs 4

# Tests for the help-topic registry (lib/core/bu_core_help_topic.sh),
# the `bu get-help` CLI surface, and the `--help` SEE ALSO back-reference.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # shellcheck source=../bu_entrypoint.sh
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"

    # Core topics (e.g. `pipeline`) are registered by the entrypoint. Unit
    # tests below operate on a clean registry; the core registration itself
    # is verified separately in test_core_pipeline_topic.
    BU_HELP_TOPIC_REGISTRY=()
    BU_HELP_TOPIC_PROPERTIES=()
}

# Helper: write a topic script with a synopsis and a heredoc body.
# $1 = file path, $2 = synopsis, $3 = body lines (already-escaped string)
_write_topic() {
    local file=$1
    local synopsis=$2
    local body=$3
    cat > "$file" <<EOF
# Synopsis: $synopsis
$body
EOF
}

# ===========================================================================
# Registration / resolve / names
# ===========================================================================

function test_topic_register_resolve_names_roundtrip { #@test
    local d="$BATS_TEST_TMPDIR/topics"
    mkdir -p "$d"
    _write_topic "$d/widgets.help.sh" "Widget subsystem" "cat <<'INNER'
Widgets help.
INNER"

    bu_help_topic_register widgets --file "$d/widgets.help.sh"

    bu_help_topic_resolve widgets
    assert_equal "${BU_RET[0]}" "$d/widgets.help.sh"

    bu_help_topic_names
    assert_equal "${BU_RET[*]}" "widgets"

    # Re-registration overwrites (same name, new file)
    _write_topic "$d/widgets2.help.sh" "Widget subsystem v2" "cat <<'INNER'
Widgets v2 help.
INNER"
    bu_help_topic_register widgets --file "$d/widgets2.help.sh"
    bu_help_topic_resolve widgets
    assert_equal "${BU_RET[0]}" "$d/widgets2.help.sh"
}

function test_topic_register_requires_readable_file { #@test
    run bu_help_topic_register bad --file "$BATS_TEST_TMPDIR/does-not-exist.help.sh"
    assert_failure

    run bu_help_topic_register '' --file /etc/hosts
    assert_failure

    run bu_help_topic_register bad
    assert_failure
}

function test_topic_register_dir_multiple_and_missing { #@test
    local d="$BATS_TEST_TMPDIR/topics"
    mkdir -p "$d"
    _write_topic "$d/alpha.help.sh" "Alpha subsystem" "cat <<'INNER'
Alpha.
INNER"
    _write_topic "$d/beta.help.sh" "Beta subsystem" "cat <<'INNER'
Beta.
INNER"

    bu_help_topic_register_dir "$d"
    bu_help_topic_names
    assert_equal "${BU_RET[*]}" "alpha beta"

    # Missing dir is success (a module may not ship topics yet)
    run bu_help_topic_register_dir "$BATS_TEST_TMPDIR/definitely-missing"
    assert_success
}

# ===========================================================================
# Derived command tables
# ===========================================================================

function test_topic_commands_table_derives_and_skips { #@test
    local d="$BATS_TEST_TMPDIR/suite"
    mkdir -p "$d"
    cat > "$d/get-widget.sh" <<'EOF'
# Synopsis: Get a widget
EOF
    cat > "$d/set-widget.sh" <<'EOF'
# Synopsis: Set a widget
EOF
    cat > "$d/other.py" <<'EOF'
# Synopsis: A python command
EOF
    cat > "$d/__helper.sh" <<'EOF'
# Synopsis: Should be skipped (dunder)
EOF
    cat > "$d/functions.lib.sh" <<'EOF'
# Synopsis: Should be skipped (functions.*)
EOF
    cat > "$d/overrides.sh" <<'EOF'
# Synopsis: Should be skipped (overrides*)
EOF

    run bu_help_topic_commands "$d"
    assert_success
    assert_output --partial "bu get-widget Get a widget"
    assert_output --partial "bu set-widget Set a widget"
    assert_output --partial "bu other A python command"
    refute_output --partial "__helper"
    refute_output --partial "functions"
    refute_output --partial "overrides"
}

function test_topic_commands_strips_bu_namespace { #@test
    local d="$BATS_TEST_TMPDIR/suite"
    mkdir -p "$d"
    cat > "$d/bu-get-widget.sh" <<'EOF'
# Synopsis: Get a widget
EOF
    cat > "$d/bu-convert-to-json.sh" <<'EOF'
# Synopsis: Convert JSONL records to a formatted JSON array
EOF

    run bu_help_topic_commands "$d"
    assert_success
    assert_output --partial "bu get-widget Get a widget"
    assert_output --partial "bu convert-to-json Convert JSONL records to a formatted JSON array"
    refute_output --partial "bu bu-"
}

function test_topic_commands_tagged_only_tagged_files { #@test
    local d="$BATS_TEST_TMPDIR/suite"
    mkdir -p "$d"
    cat > "$d/get-widget.sh" <<'EOF'
# Help-Topic: widgets
# Synopsis: Get a widget
EOF
    cat > "$d/set-widget.sh" <<'EOF'
# Help-Topic: gadgets
# Synopsis: Set a widget
EOF
    cat > "$d/other.sh" <<'EOF'
# Synopsis: No topic tag
EOF

    run bu_help_topic_commands_tagged widgets "$d"
    assert_success
    assert_output --partial "bu get-widget Get a widget"
    refute_output --partial "set-widget"
    refute_output --partial "other"
}

# ===========================================================================
# bu_help_topic_for_script precedence
# ===========================================================================

function test_topic_for_script_precedence { #@test
    local d="$BATS_TEST_TMPDIR"
    mkdir -p "$d/subsys"
    _write_topic "$d/topic.help.sh" "Shared topic" "cat <<'INNER'
Shared.
INNER"

    bu_help_topic_register widgets --file "$d/topic.help.sh"
    bu_help_topic_register subsys --file "$d/topic.help.sh"

    # Explicit # Help-Topic: header beats parent dir
    cat > "$d/subsys/cmd.sh" <<'EOF'
# Help-Topic: widgets
EOF
    bu_help_topic_for_script "$d/subsys/cmd.sh"
    local rc=$?
    assert_equal "$rc" 0
    assert_equal "${BU_RET[0]}" widgets

    # Parent-dir fallback
    cat > "$d/subsys/plain.sh" <<'EOF'
# no help-topic header
EOF
    bu_help_topic_for_script "$d/subsys/plain.sh"
    rc=$?
    assert_equal "$rc" 0
    assert_equal "${BU_RET[0]}" subsys

    # Unregistered topic -> failure
    cat > "$d/subsys/other.sh" <<'EOF'
# Help-Topic: nosuchtopic
EOF
    run bu_help_topic_for_script "$d/subsys/other.sh"
    assert_failure
}

# ===========================================================================
# Rendering
# ===========================================================================

function test_topic_render_live_values_and_isolation { #@test
    local d="$BATS_TEST_TMPDIR"
    cat > "$d/widgets.help.sh" <<'EOF'
# Synopsis: Widget subsystem
export TOPIC_LEAKED=should-not-escape
cat <<INNER
${BU_TPUT_BOLD}Widgets help.${BU_TPUT_RESET}
The live value is: ${LIVE_TOPIC_VAR}
INNER
EOF
    export LIVE_TOPIC_VAR=hello-world

    # 1) Substitutes live env values and given tput args
    local out
    out=$(__bu_help_topic_render "$d/widgets.help.sh" "[BOLD]" "[RESET]")
    [[ "$out" == *"hello-world"* ]]
    [[ "$out" == *"[BOLD]Widgets help.[RESET]"* ]]

    # 2) Cannot leak variables into the caller (direct call, NOT in $())
    __bu_help_topic_render "$d/widgets.help.sh" "" "" >/dev/null
    [[ -z "${TOPIC_LEAKED:-}" ]]

    # 3) Emits no escapes when tput args are blank
    out=$(__bu_help_topic_render "$d/widgets.help.sh" "" "")
    [[ "$out" == *"Widgets help."* ]]
    [[ "$out" != *$'\x1B'* ]]
}

# ===========================================================================
# bu get-help CLI
# ===========================================================================

function test_get_help_jsonl_lists_records { #@test
    local d="$BATS_TEST_TMPDIR"
    _write_topic "$d/widgets.help.sh" "Widget subsystem" "cat <<'INNER'
Widgets help.
INNER"
    bu_help_topic_register widgets --file "$d/widgets.help.sh"

    run bu get-help --format jsonl
    assert_success
    assert_equal "$(printf '%s\n' "$output" | jq -r '.topic')" "widgets"
    assert_equal "$(printf '%s\n' "$output" | jq -r '.synopsis')" "Widget subsystem"
    assert_equal "$(printf '%s\n' "$output" | jq -r '.file')" "$d/widgets.help.sh"
    assert [ -n "$(printf '%s\n' "$output" | jq -r '.source')" ]
}

function test_get_help_render_cli { #@test
    local d="$BATS_TEST_TMPDIR"
    cat > "$d/widgets.help.sh" <<'EOF'
# Synopsis: Widget subsystem
cat <<INNER
Widgets help.
Live: ${LIVE_TOPIC_VAR}
INNER
EOF
    bu_help_topic_register widgets --file "$d/widgets.help.sh"
    export LIVE_TOPIC_VAR=cli-value

    run bu get-help widgets
    assert_success
    assert_output --partial "Widgets help."
    assert_output --partial "Live: cli-value"
    [[ "$output" != *$'\x1B'* ]]
}

function test_get_help_unknown_known_mix { #@test
    local d="$BATS_TEST_TMPDIR"
    _write_topic "$d/widgets.help.sh" "Widget subsystem" "cat <<'INNER'
Widgets help.
INNER"
    bu_help_topic_register widgets --file "$d/widgets.help.sh"

    run bu get-help widgets nosuchtopic
    assert_failure
    assert_output --partial "Widgets help."
    assert_output --partial "Unknown help topic"
    assert_output --partial "widgets"
    assert_output --partial "nosuchtopic"
}

# ===========================================================================
# SEE ALSO back-reference in --help
# ===========================================================================

function test_see_also_back_reference { #@test
    local topic_dir="$BATS_TEST_TMPDIR/topics"
    mkdir -p "$topic_dir"
    _write_topic "$topic_dir/widgets.help.sh" "Widget subsystem" "cat <<'INNER'
Widgets help.
INNER"

    local cmd_dir="$BATS_TEST_TMPDIR/commands"
    mkdir -p "$cmd_dir"
    cat > "$cmd_dir/get-widget.sh" <<'CMDEOF'
#!/usr/bin/env bash
# Dispatch: source
# Help-Topic: widgets
# Synopsis: Get a widget
function __bu_get_widget_main()
{
    source "$BU_NULL"
    bu_scope_push_function
    bu_run_log_command "$@"
    local is_help=false
    local error_msg=
    local shift_by=
    while (($#))
    do
        bu_parse_multiselect $# "$1"
        case "$1" in
        -h|--help) is_help=true ;;
        *)
            bu_parse_error_enum "$1"
            ;;
        esac
        if "$is_help"; then break; fi
        shift "$shift_by"
    done
    if bu_env_is_in_autocomplete; then bu_autocomplete; return 0; fi
    if "$is_help"; then
        bu_autohelp --description "Get a widget."
        return 0
    fi
    bu_scope_pop_function
}
__bu_get_widget_main "$@"
CMDEOF

    local preinit="$BATS_TEST_TMPDIR/widgets-preinit.sh"
    cat > "$preinit" <<EOF
source "\$BU_NULL"
bu_help_topic_register_dir "$topic_dir"
bu_preinit_register_user_defined_subcommand_file "$cmd_dir/get-widget.sh" get-widget source
EOF

    run bash -c '
        export BU_TOP_LEVEL_MODULE=widgets
        export BU_MODULE_LIST="widgets:0.1.0:$1;"
        source "$2"/bu_entrypoint.sh >/dev/null 2>&1
        bu get-widget --help
    ' _ "$preinit" "$DIR"/..
    assert_success
    assert_output --partial "SEE ALSO"
    assert_output --partial "get-help widgets"
    assert_output --partial "(the widgets subsystem topic)"

    # A core command with no registered topic has no SEE ALSO back-reference.
    run bu get-module --help
    assert_success
    refute_output --partial "SEE ALSO"
}

# ===========================================================================
# Core topic (registered by the entrypoint)
# ===========================================================================

function test_core_pipeline_topic { #@test
    run bash -c '
        export BU_TOP_LEVEL_MODULE=coretopic
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        bu_help_topic_names
        printf "%s\n" "${BU_RET[@]}"
    ' _ "$DIR"/..
    assert_success
    assert_output --partial "pipeline"

    run bash -c '
        export BU_TOP_LEVEL_MODULE=coretopic
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        bu get-help pipeline
    ' _ "$DIR"/..
    assert_success
    assert_output --partial "object protocol"
    assert_output --partial "bu query-object"
    [[ "$output" != *$'\x1B'* ]]
}
