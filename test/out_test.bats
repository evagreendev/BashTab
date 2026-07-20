#!/usr/bin/env -S bats --jobs 16

# Unit tests for lib/core/bu_core_out.sh (structured output) and the
# cmdlet wrapper commands (format-table, format-list, convert-to-*, out-default).
#
# All tests are TTY-independent: stdout inside $( ) / run is a pipe, so
# `bu out` auto-dispatch deterministically resolves to jsonl, and table
# headers are never bold.

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
}

# ===========================================================================
# bu_out_record
# ===========================================================================

function test_bu_out_record_basic { #@test
    run bu_out_record name=bashtab version=0.1.0
    assert_success
    assert_output '{"name":"bashtab","version":"0.1.0"}'
}

function test_bu_out_record_escaping { #@test
    # Quotes, backslashes, newlines and unicode must survive the JSON round-trip
    local out
    out=$(bu_out_record 'weird=a"b\c' $'multi=line1\nline2' 'unicode=✓' | jq -r '.weird + "|" + .multi + "|" + .unicode')
    assert_equal "$out" $'a"b\\c|line1\nline2|✓'
}

function test_bu_out_record_typed_values { #@test
    run bu_out_record alive:=true retries:=3
    assert_success
    assert_output '{"alive":true,"retries":3}'
}

function test_bu_out_record_invalid_key { #@test
    run bu_out_record 'bad-key=x'
    assert_failure
}

function test_bu_out_record_missing_equals { #@test
    run bu_out_record novalue
    assert_failure
}

# ===========================================================================
# bu_out_from_tsv / bu_out_from_lines
# ===========================================================================

function test_bu_out_from_tsv_basic { #@test
    local out
    out=$(printf 'bashtab\t0.1.0\t/x\nmyapp\t-\t/y\n' | bu_out_from_tsv --columns name,version,path)
    assert_equal "$out" '{"name":"bashtab","version":"0.1.0","path":"/x"}
{"name":"myapp","version":"-","path":"/y"}'
}

function test_bu_out_from_tsv_extra_fields_dropped { #@test
    local out
    out=$(printf 'a\t1\tEXTRA\n' | bu_out_from_tsv --columns name,version)
    assert_equal "$out" '{"name":"a","version":"1"}'
}

function test_bu_out_from_tsv_missing_fields_absent { #@test
    local out
    out=$(printf 'b\n' | bu_out_from_tsv --columns name,version)
    assert_equal "$out" '{"name":"b"}'
}

function test_bu_out_from_tsv_blank_lines_skipped { #@test
    local out
    out=$(printf 'a\t1\n\nb\t2\n' | bu_out_from_tsv --columns name,version)
    assert_equal "$out" '{"name":"a","version":"1"}
{"name":"b","version":"2"}'
}

function test_bu_out_from_tsv_requires_columns { #@test
    run bu_out_from_tsv </dev/null
    assert_failure
}

function test_bu_out_from_lines_basic { #@test
    local out
    out=$(printf 'a.txt\nb.txt\n' | bu_out_from_lines --column file)
    assert_equal "$out" '{"file":"a.txt"}
{"file":"b.txt"}'
}

# ===========================================================================
# bu_format_table (buffered)
# ===========================================================================

function test_bu_format_table_basic { #@test
    local out
    out=$(printf '%s\n' '{"name":"bashtab","version":"0.1.0"}' '{"name":"myapp","version":"-"}' \
        | bu_format_table --columns name,version)
    assert_equal "$out" 'name     version
-------  -------
bashtab  0.1.0
myapp    -'
}

function test_bu_format_table_default_columns_and_value_types { #@test
    # No --columns: keys of the first record in insertion order.
    # Numbers/booleans render via tostring, null renders empty.
    local out
    out=$(printf '%s\n' '{"name":"x","n":3,"ok":true,"missing":null}' | bu_format_table)
    assert_equal "$out" 'name  n  ok    missing
----  -  ----  -------
x     3  true'
}

function test_bu_format_table_truncates_to_terminal_width { #@test
    local out
    out=$(COLUMNS=30; printf '%s\n' '{"name":"bashtab","path":"/a/very/long/path/that/exceeds"}' \
        | bu_format_table --columns name,path)
    assert_equal "$out" 'name     path
-------  ---------------------
bashtab  /a/very/long/path/th…'
}

function test_bu_format_table_empty_input_no_output { #@test
    local out
    out=$(printf '' | bu_format_table --columns name,version)
    assert_equal "$out" ''
}

function test_bu_format_table_no_trailing_spaces { #@test
    local out
    # grep exits 1 when it finds zero trailing-space matches; that is the pass case
    out=$(printf '%s\n' '{"name":"a"}' '{"name":"a-longer-name"}' | bu_format_table --columns name | grep -c ' $' || :)
    assert_equal "$out" '0'
}

function test_bu_format_table_colors_wrap_cells { #@test
    # Explicit --colors applies ANSI even when piped; header stays plain (not a TTY)
    local out
    out=$(printf '%s\n' '{"name":"x"}' | bu_format_table --columns name --colors name=red | grep -c $'\033')
    assert_equal "$out" '1'
}

# ===========================================================================
# bu_format_table --stream
# ===========================================================================

function test_bu_format_table_stream_proportional_widths { #@test
    local out
    out=$(COLUMNS=40; printf '%s\n' '{"name":"bashtab","version":"0.1.0"}' '{"name":"myapp","version":"-"}' \
        | bu_format_table --stream --columns name,version)
    assert_equal "$out" 'name                 version
-------------------  -------------------
bashtab              0.1.0
myapp                -'
}

function test_bu_format_table_stream_requires_columns { #@test
    run bu_format_table --stream </dev/null
    assert_failure
}

# ===========================================================================
# bu_format_list / json / jsonl / tsv
# ===========================================================================

function test_bu_format_list_basic { #@test
    local out
    out=$(printf '%s\n' '{"name":"bashtab","version":"0.1.0"}' '{"name":"myapp","version":"-"}' | bu_format_list)
    assert_equal "$out" 'name    : bashtab
version : 0.1.0

name    : myapp
version : -'
}

function test_bu_format_json_array { #@test
    local out
    out=$(printf '%s\n' '{"a":1}' '{"a":2}' | bu_format_json | jq -c .)
    assert_equal "$out" '[{"a":1},{"a":2}]'
}

function test_bu_format_jsonl_compacts { #@test
    local out
    out=$(printf '%s\n' '{ "a": 1 }' | bu_format_jsonl)
    assert_equal "$out" '{"a":1}'
}

function test_bu_format_tsv_columns { #@test
    local out
    out=$(printf '%s\n' '{"name":"x","path":"/p"}' | bu_format_tsv --columns name,path)
    assert_equal "$out" $'x\t/p'
}

# ===========================================================================
# bu_out dispatch
# ===========================================================================

function test_bu_out_piped_defaults_to_jsonl { #@test
    local out
    out=$(printf '%s\n' '{"a":1}' | bu_out)
    assert_equal "$out" '{"a":1}'
}

function test_bu_out_env_override { #@test
    local out
    out=$(printf '%s\n' '{"a":1}' | BU_OUTPUT_FORMAT=json bu_out | jq -c .)
    assert_equal "$out" '[{"a":1}]'
}

function test_bu_out_explicit_format_beats_env { #@test
    local out
    out=$(printf '%s\n' '{"a":1}' | BU_OUTPUT_FORMAT=json bu_out --format tsv --columns a)
    assert_equal "$out" '1'
}

function test_bu_out_invalid_format { #@test
    run bu_out --format yaml </dev/null
    assert_failure
}

# ===========================================================================
# Transforms: bu_out_where / bu_out_select / bu_out_sort_by
# ===========================================================================

function test_bu_out_where_filters { #@test
    local out
    out=$(printf '%s\n' '{"name":"a","type":"source"}' '{"name":"b","type":"execute"}' | bu_out_where '.type == "source"')
    assert_equal "$out" '{"name":"a","type":"source"}'
}

function test_bu_out_where_requires_expression { #@test
    run bu_out_where </dev/null
    assert_failure
}

function test_bu_out_select_projects_and_reorders { #@test
    local out
    out=$(printf '%s\n' '{"name":"a","version":"1","path":"/x"}' | bu_out_select version,name)
    assert_equal "$out" '{"version":"1","name":"a"}'
}

function test_bu_out_select_renames { #@test
    local out
    out=$(printf '%s\n' '{"name":"a","version":"1"}' | bu_out_select name,ver=version)
    assert_equal "$out" '{"name":"a","ver":"1"}'
}

function test_bu_out_select_invalid_key { #@test
    run bu_out_select 'bad-key=x' </dev/null
    assert_failure
}

function test_bu_out_sort_by_ascending { #@test
    local out
    out=$(printf '%s\n' '{"n":3}' '{"n":1}' '{"n":2}' | bu_out_sort_by n)
    assert_equal "$out" '{"n":1}
{"n":2}
{"n":3}'
}

function test_bu_out_sort_by_descending { #@test
    local out
    out=$(printf '%s\n' '{"n":3}' '{"n":1}' '{"n":2}' | bu_out_sort_by n --desc)
    assert_equal "$out" '{"n":3}
{"n":2}
{"n":1}'
}

function test_bu_out_sort_by_strings { #@test
    local out
    out=$(printf '%s\n' '{"name":"gamma"}' '{"name":"alpha"}' | bu_out_sort_by name | jq -r .name | tr '\n' ' ')
    assert_equal "$out" 'alpha gamma '
}

function test_bu_out_sort_by_requires_key { #@test
    run bu_out_sort_by </dev/null
    assert_failure
}

# ===========================================================================
# Column labels (key:Label)
# ===========================================================================

function test_bu_format_table_labels { #@test
    local out
    out=$(printf '%s\n' '{"name":"bashtab","version":"0.1.0"}' | bu_format_table --columns name:Module,version)
    assert_equal "$out" 'Module   version
-------  -------
bashtab  0.1.0'
}

function test_bu_format_table_label_widens_column { #@test
    local out
    out=$(printf '%s\n' '{"name":"x"}' | bu_format_table --columns name:ModuleName)
    assert_equal "$out" 'ModuleName
----------
x'
}

function test_bu_format_table_label_with_spaces { #@test
    local out
    out=$(printf '%s\n' '{"name":"x","version":"1"}' | bu_format_table --columns 'name:Module Name,version')
    assert_equal "$out" 'Module Name  version
-----------  -------
x            1'
}

function test_bu_format_list_labels { #@test
    local out
    out=$(printf '%s\n' '{"name":"bashtab","version":"0.1.0"}' | bu_format_list --columns name:Module,version)
    assert_equal "$out" 'Module  : bashtab
version : 0.1.0'
}

function test_bu_format_table_stream_labels { #@test
    local out
    out=$(COLUMNS=40; printf '%s\n' '{"name":"bashtab","version":"0.1.0"}' | bu_format_table --stream --columns name:Module,version)
    assert_equal "$out" 'Module               version
-------------------  -------------------
bashtab              0.1.0'
}

function test_bu_format_tsv_strips_labels { #@test
    local out
    out=$(printf '%s\n' '{"name":"x","version":"1"}' | bu_format_tsv --columns name:Module,version)
    assert_equal "$out" $'x\t1'
}

function test_bu_format_table_colors_use_key_not_label { #@test
    # --colors refers to the record key even when the display label differs
    local out
    out=$(printf '%s\n' '{"name":"x"}' | bu_format_table --columns name:Module --colors name=red | grep -c $'\033')
    assert_equal "$out" '1'
}

# ===========================================================================
# Integration: bu commands with structured output
# ===========================================================================

function test_bu_get_module_piped_defaults_to_jsonl { #@test
    local out
    out=$(BU_MODULE_LIST="alpha:1.0.0:/a" bu get-module)
    assert_equal "$out" '{"name":"alpha","version":"1.0.0","path":"/a"}'
}

function test_bu_get_module_json_array { #@test
    local out
    out=$(BU_MODULE_LIST="alpha:1.0.0:/tmp/alpha;beta:-:/opt/beta" bu get-module --format json | jq -c .)
    assert_equal "$out" '[{"name":"alpha","version":"1.0.0","path":"/tmp/alpha"},{"name":"beta","version":"-","path":"/opt/beta"}]'
}

function test_bu_get_module_columns { #@test
    local out
    out=$(BU_MODULE_LIST="alpha:1.0.0:/a" bu get-module --format tsv --columns name,version)
    assert_equal "$out" $'alpha\t1.0.0'
}

function test_bu_get_command_metadata { #@test
    local out
    out=$(bu get-command | jq -c 'select(.name == "get-module")')
    assert_equal "$out" '{"name":"get-module","verb":"get","noun":"module","namespace":"bu","type":"source"}'
}

function test_bu_get_command_multi_word_verb { #@test
    # convert-to is a multi-word verb (BU_MULTI_WORD_VERBS): noun is jsonl, not to-jsonl
    local out
    out=$(bu get-command | jq -c 'select(.name == "convert-to-jsonl")')
    assert_equal "$out" '{"name":"convert-to-jsonl","verb":"convert-to","noun":"jsonl","namespace":"bu","type":"source"}'
}

function test_bu_get_command_verb_filter_multi_word { #@test
    local out
    out=$(bu get-command --verb convert-to | jq -sc 'map(.name)')
    assert_equal "$out" '["convert-to-json","convert-to-jsonl","convert-to-tsv"]'
}

function test_bu_get_command_table_header { #@test
    # Column padding depends on the longest registered command name, which
    # varies with the user's modules, so assert on structure not exact widths
    local out
    out=$(bu get-command --format table | head -1)
    assert_regex "$out" '^name +verb +noun +namespace +type *$'
}

function test_bu_pipeline_format_table_cmdlet { #@test
    local out
    out=$(BU_MODULE_LIST="alpha:1.0.0:/a" bu get-module | bu format-table --columns name,version)
    assert_equal "$out" 'name   version
-----  -------
alpha  1.0.0'
}

function test_bu_pipeline_convert_to_json_cmdlet { #@test
    local out
    out=$(BU_MODULE_LIST="alpha:1.0.0:/a" bu get-module | bu convert-to-json | jq -c 'map(.name)')
    assert_equal "$out" '["alpha"]'
}

function test_bu_pipeline_out_default_cmdlet { #@test
    local out
    out=$(BU_MODULE_LIST="alpha:1.0.0:/a" bu get-module | bu out-default --format tsv --columns name)
    assert_equal "$out" 'alpha'
}

function test_bu_pipeline_jq_as_where_object { #@test
    # The PowerShell pipeline payoff: jq between bu commands as Where-Object
    local out
    out=$(bu get-command | jq -c 'select(.verb == "get" and .namespace == "bu")' | bu out-default --format tsv --columns name | tr '\n' ' ')
    assert_equal "$out" 'get-command get-module '
}

function test_bu_pipeline_where_select_sort_table { #@test
    # Full transform chain piped into a table sink
    local out
    out=$(bu get-command | bu_out_where '.namespace == "bu"' | bu_out_select name,verb | bu_out_sort_by name | bu_format_table | head -3)
    assert_equal "$out" 'name                     verb
-----------------------  ------------
convert-from-lines       convert-from'
}

# ===========================================================================
# Cmdlet wrappers: where-object / select-object / sort-object /
# convert-from-* / new-record
# ===========================================================================

function test_bu_where_object_cmdlet { #@test
    local out
    out=$(bu get-command | bu where-object '.verb == "get" and .namespace == "bu"' | jq -r .name | tr '\n' ' ')
    assert_equal "$out" 'get-command get-module '
}

function test_bu_where_object_missing_expression { #@test
    run bu where-object </dev/null
    assert_failure
}

function test_bu_select_object_cmdlet { #@test
    local out
    out=$(BU_MODULE_LIST="alpha:1.0.0:/a" bu get-module | bu select-object name,ver=version)
    assert_equal "$out" '{"name":"alpha","ver":"1.0.0"}'
}

function test_bu_sort_object_cmdlet { #@test
    local out
    out=$(printf '%s\n' '{"n":3}' '{"n":1}' | bu sort-object n | jq -r .n | tr '\n' ' ')
    assert_equal "$out" '1 3 '
}

function test_bu_sort_object_cmdlet_desc { #@test
    local out
    out=$(printf '%s\n' '{"n":3}' '{"n":1}' | bu sort-object n --desc | jq -r .n | tr '\n' ' ')
    assert_equal "$out" '3 1 '
}

function test_bu_sort_object_missing_key { #@test
    run bu sort-object </dev/null
    assert_failure
}

function test_bu_convert_from_tsv_roundtrip { #@test
    # convert-to-tsv | convert-from-tsv is a lossless round trip for plain values
    local out
    out=$(BU_MODULE_LIST="alpha:1.0.0:/a" bu get-module | bu convert-to-tsv --columns name,version | bu convert-from-tsv --columns name,version)
    assert_equal "$out" '{"name":"alpha","version":"1.0.0"}'
}

function test_bu_convert_from_lines_cmdlet { #@test
    local out
    out=$(printf 'a.txt\nb.txt\n' | bu convert-from-lines --column file)
    assert_equal "$out" '{"file":"a.txt"}
{"file":"b.txt"}'
}

function test_bu_new_record_cmdlet { #@test
    run bu new-record name=bashtab alive:=true retries:=3
    assert_success
    assert_output '{"name":"bashtab","alive":true,"retries":3}'
}

function test_bu_get_command_convert_from_multi_word_verb { #@test
    # convert-from is a multi-word verb: noun is tsv, not from-tsv
    local out
    out=$(bu get-command | jq -c 'select(.name == "convert-from-tsv")')
    assert_equal "$out" '{"name":"convert-from-tsv","verb":"convert-from","noun":"tsv","namespace":"bu","type":"source"}'
}

function test_bu_full_powershell_pipeline { #@test
    # The whole story in one pipeline: produce | Where | Select | Sort | Format
    local out
    out=$(bu get-command \
        | bu where-object '.namespace == "bu" and .verb == "convert-to"' \
        | bu select-object name \
        | bu sort-object name \
        | bu format-table)
    assert_equal "$out" 'name
----------------
convert-to-json
convert-to-jsonl
convert-to-tsv'
}

# ===========================================================================
# Pipeline field completion (__bu_out_complete_pipeline_fields)
# ===========================================================================

function test_pipeline_fields_registry_binding_style { #@test
    # The fzf binding exposes the producer text as command_line_front_before_pipe
    local command_line_front_before_pipe="bu get-command | "
    __bu_out_complete_pipeline_fields ""
    assert_equal "${BU_RET[*]}" "name verb noun namespace type"
}

function test_pipeline_fields_registry_prefix_with_flags { #@test
    # Producer carries flags: longest-prefix registry match still applies
    local command_line_front_before_pipe="bu get-command --verb get | "
    __bu_out_complete_pipeline_fields ""
    assert_equal "${BU_RET[*]}" "name verb noun namespace type"
}

function test_pipeline_fields_ts_pipe_before { #@test
    # The tree-sitter binding exposes the producer text as pipe_before
    local pipe_before="bu get-module | "
    __bu_out_complete_pipeline_fields ""
    assert_equal "${BU_RET[*]}" "name version path"
}

function test_pipeline_fields_comp_words_fallback { #@test
    # No binding locals: walk COMP_WORDS for the last standalone pipe
    local command_line_front_before_pipe= pipe_before=
    COMP_WORDS=(bu get-command \| bu select-object "")
    COMP_CWORD=4
    __bu_out_complete_pipeline_fields ""
    assert_equal "${BU_RET[*]}" "name verb noun namespace type"
}

function test_pipeline_fields_no_pipe_empty { #@test
    local command_line_front_before_pipe= pipe_before=
    COMP_WORDS=(bu select-object na)
    COMP_CWORD=2
    run __bu_out_complete_pipeline_fields "na"
    assert_failure
}

function test_pipeline_fields_comma_excludes_used { #@test
    local command_line_front_before_pipe="bu get-command | "
    __bu_out_complete_pipeline_fields "name,ve"
    assert_equal "${BU_RET[*]}" "name,verb name,noun name,namespace name,type"
}

function test_pipeline_fields_dot_mode { #@test
    local command_line_front_before_pipe="bu get-command | "
    __bu_out_complete_pipeline_fields --dot ""
    assert_equal "${BU_RET[*]}" ".name .verb .noun .namespace .type"
}

function test_pipeline_fields_register_custom_producer { #@test
    bu_register_output_fields "bu get-pokemon" name id type hp attack
    local command_line_front_before_pipe="bu get-pokemon --type fire | "
    __bu_out_complete_pipeline_fields ""
    assert_equal "${BU_RET[*]}" "name id type hp attack"
}

function test_pipeline_fields_probe_opt_in { #@test
    print_record() { printf '%s\n' '{"alpha":1,"beta":2}'; }
    local command_line_front_before_pipe="print_record | "
    BU_OUT_PROBE_PIPELINE=true
    BU_OUT_PROBE_COMMANDS[print_record]=1
    __bu_out_complete_pipeline_fields ""
    assert_equal "${BU_RET[*]}" "alpha beta"
}

function test_pipeline_fields_probe_disabled_by_default { #@test
    print_record() { printf '%s\n' '{"alpha":1,"beta":2}'; }
    local command_line_front_before_pipe="print_record | "
    BU_OUT_PROBE_PIPELINE=false
    BU_OUT_PROBE_COMMANDS[print_record]=1
    run __bu_out_complete_pipeline_fields ""
    assert_failure
}

function test_pipeline_fields_probe_requires_allowlist { #@test
    print_record() { printf '%s\n' '{"alpha":1,"beta":2}'; }
    local command_line_front_before_pipe="print_record | "
    BU_OUT_PROBE_PIPELINE=true
    run __bu_out_complete_pipeline_fields ""
    assert_failure
}

function test_e2e_select_object_pipeline_fields { #@test
    # Full completion driver: bu get-command | bu select-object <TAB>
    local command_line_front_before_pipe="bu get-command | "
    bu_autocomplete_get_autocompletions bu select-object ""
    assert_equal "${COMPREPLY[*]}" "name verb noun namespace type"
}

function test_e2e_select_object_comma_continuation { #@test
    local command_line_front_before_pipe="bu get-command | "
    bu_autocomplete_get_autocompletions bu select-object name,ve
    assert_equal "${COMPREPLY[*]}" "name,verb"
}

function test_e2e_where_object_dot_fields { #@test
    local command_line_front_before_pipe="bu get-command | "
    bu_autocomplete_get_autocompletions bu where-object ""
    assert_equal "${COMPREPLY[*]}" ".name .verb .noun .namespace .type"
}

function test_e2e_sort_object_pipeline_fields { #@test
    local pipe_before="bu get-module | "
    bu_autocomplete_get_autocompletions bu sort-object ""
    assert_equal "${COMPREPLY[*]}" "name version path"
}

function test_e2e_format_table_columns_pipeline_fields { #@test
    local command_line_front_before_pipe="bu get-command | "
    bu_autocomplete_get_autocompletions bu format-table --columns ""
    assert_equal "${COMPREPLY[*]}" "name verb noun namespace type"
}

function test_e2e_no_pipeline_shows_hint_only { #@test
    bu_autocomplete_get_autocompletions bu select-object na
    assert_equal "${COMPREPLY[0]}" "Hint: field (from pipeline producer)"
}

# ===========================================================================
# Cmdlets end at Out-Default: table on a terminal, JSONL when piped
# ===========================================================================

function test_cmdlets_jsonl_when_piped { #@test
    # $( ) capture is not a terminal, so transforms stay JSONL (already covered
    # by the cmdlet tests above); assert explicitly for select-object
    local out
    out=$(BU_MODULE_LIST="a:1.0.0:/x" bu get-module | bu select-object name,version)
    assert_equal "$out" '{"name":"a","version":"1.0.0"}'
}

function test_cmdlets_table_when_terminal { #@test
    # script(1) allocates a pty, so the pipeline terminus sees a terminal and
    # Out-Default renders a table (bold header ANSI stripped)
    local helper=$BATS_TEST_TMPDIR/pty_select.sh
    cat > "$helper" <<EOF
source "$DIR/../bu_entrypoint.sh" >/dev/null 2>&1
BU_MODULE_LIST="a:1.0.0:/x" bu get-module | bu select-object name,version
EOF
    local out
    out=$(script -qec "bash $helper" /dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g;s/\x1b(B//g')
    assert_equal "$out" 'name  version
----  -------
a     1.0.0'
}

function test_cmdlets_env_format_override { #@test
    # BU_OUTPUT_FORMAT flows through the transform's implicit bu_out
    local out
    out=$(BU_MODULE_LIST="a:1.0.0:/x" bu get-module | BU_OUTPUT_FORMAT=tsv bu select-object name)
    assert_equal "$out" 'a'
}

function test_cmdlets_intermediate_stays_jsonl { #@test
    # Even on a terminal, a non-terminus transform must emit JSONL: here
    # where-object is mid-pipeline, convert-to-tsv is the terminus
    local helper=$BATS_TEST_TMPDIR/pty_chain.sh
    cat > "$helper" <<EOF
source "$DIR/../bu_entrypoint.sh" >/dev/null 2>&1
BU_MODULE_LIST="a:1.0.0:/x;b:2.0.0:/y" bu get-module | bu where-object '.name == "b"' | bu convert-to-tsv --columns name
EOF
    local out
    out=$(script -qec "bash $helper" /dev/null | tr -d '\r')
    assert_equal "$out" 'b'
}

# ===========================================================================
# bu query-object (SQL-style compositor)
# ===========================================================================

function test_bu_query_object_full_query { #@test
    local out
    out=$(bu get-command | bu query-object --where '.type == "source"' --select name,verb --order-by verb --first 2 --format tsv --columns name,verb)
    assert_equal "$out" $'convert-from-lines\tconvert-from\nconvert-from-tsv\tconvert-from'
}

function test_bu_query_object_bare_keywords { #@test
    # SQL keywords without dashes
    local out
    out=$(bu get-command | bu query-object where '.type == "source"' select name,verb order-by verb first 2 --format tsv --columns name,verb)
    assert_equal "$out" $'convert-from-lines\tconvert-from\nconvert-from-tsv\tconvert-from'
}

function test_bu_query_object_clause_order_invariance { #@test
    local a b
    a=$(bu get-command | bu query-object where '.namespace == "bu"' select name order-by name --format jsonl)
    b=$(bu get-command | bu query-object --order-by name --select name --where '.namespace == "bu"' --format jsonl)
    assert_equal "$a" "$b"
}

function test_bu_query_object_bare_dashed_equivalence { #@test
    local a b
    a=$(bu get-command | bu query-object where '.verb == "get"' select name order-by name --format jsonl)
    b=$(bu get-command | bu query-object --where '.verb == "get"' --select name --order-by name --format jsonl)
    assert_equal "$a" "$b"
    assert_equal "$a" '{"name":"get-command"}
{"name":"get-module"}'
}

function test_bu_query_object_rename_then_order_by_alias { #@test
    # SQL semantics: ORDER BY sees SELECT aliases
    local out
    out=$(BU_MODULE_LIST="b:2.0.0:/x;a:1.0.0:/y" bu get-module | bu query-object select name,ver=version order-by ver)
    assert_equal "$out" '{"name":"a","ver":"1.0.0"}
{"name":"b","ver":"2.0.0"}'
}

function test_bu_query_object_multiple_where_anded { #@test
    local out
    out=$(bu get-command | bu query-object where '.namespace == "bu"' where '.verb == "get"' select name --format tsv --columns name)
    assert_equal "$out" $'get-command\nget-module'
}

function test_bu_query_object_desc { #@test
    local out
    out=$(bu get-command | bu query-object order-by name desc first 2 select name --format tsv --columns name)
    assert_equal "$out" $'where-object\nsort-object'
}

function test_bu_query_object_invalid_first { #@test
    run bu query-object first abc </dev/null
    assert_failure
}

function test_bu_query_object_no_clauses_passthrough { #@test
    local out
    out=$(BU_MODULE_LIST="a:1.0.0:/x" bu get-module | bu query-object)
    assert_equal "$out" '{"name":"a","version":"1.0.0","path":"/x"}'
}

function test_bu_query_object_metadata { #@test
    local out
    out=$(bu get-command | jq -c 'select(.name == "query-object")')
    assert_equal "$out" '{"name":"query-object","verb":"query","noun":"object","namespace":"bu","type":"source"}'
}

function test_e2e_query_object_clause_completion { #@test
    # Bare keywords are suggested as options, and clause values get pipeline fields
    local command_line_front_before_pipe="bu get-command | "
    bu_autocomplete_get_autocompletions bu query-object se
    assert_equal "${COMPREPLY[*]}" "select"
    bu_autocomplete_get_autocompletions bu query-object select ""
    assert_equal "${COMPREPLY[*]}" "name verb noun namespace type"
}

function test_e2e_query_object_where_dot_completion { #@test
    local command_line_front_before_pipe="bu get-command | "
    bu_autocomplete_get_autocompletions bu query-object where ""
    assert_equal "${COMPREPLY[*]}" ".name .verb .noun .namespace .type"
}

# ===========================================================================
# Alias merging in option completion (--select, select, SELECT are one row)
# ===========================================================================

function test_alias_merged_single_row { #@test
    # --select/select merge into one row (the first form); no bare select row
    bu_autocomplete_get_autocompletions bu query-object ""
    local count=0 candidate
    for candidate in "${COMPREPLY[@]}"
    do
        [[ "$candidate" == "--select" || "$candidate" == "select" ]] && ((count++))
    done
    assert_equal "$count" 1
    assert_equal "${COMPREPLY[0]}" "--select"
}

function test_alias_merged_metadata_aka { #@test
    # The merged row's metadata lists the alternative forms
    bu_autocomplete_get_autocompletions bu query-object ""
    assert_regex "${BU_COMPREPLY_METADATA[*]}" 'aka select'
    assert_regex "${BU_COMPREPLY_METADATA[*]}" 'aka order-by'
}

function test_alias_display_follows_typed_prefix { #@test
    # Typing the bare keyword's prefix switches the row to that form so the
    # compgen prefix filter keeps it
    bu_autocomplete_get_autocompletions bu query-object se
    assert_equal "${COMPREPLY[*]}" "select"
}

function test_alias_excluded_after_any_form_used { #@test
    # Using the bare form excludes the whole alias group
    bu_autocomplete_get_autocompletions bu query-object select name ""
    local candidate
    for candidate in "${COMPREPLY[@]}"
    do
        refute_equal "$candidate" "--select"
        refute_equal "$candidate" "select"
    done
    # Other clauses are still offered
    local has_where=false
    for candidate in "${COMPREPLY[@]}"
    do
        [[ "$candidate" == "--where" ]] && has_where=true
    done
    assert_equal "$has_where" true
}

function test_alias_non_alias_pairs_not_merged { #@test
    # -v and --verb normalize differently: both rows remain
    bu_autocomplete_get_autocompletions bu get-command ""
    local has_short=false has_long=false candidate
    for candidate in "${COMPREPLY[@]}"
    do
        [[ "$candidate" == "-v" ]] && has_short=true
        [[ "$candidate" == "--verb" ]] && has_long=true
    done
    assert_equal "$has_short" true
    assert_equal "$has_long" true
}
