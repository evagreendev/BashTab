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
-----------------------  ----------
convert-to-json          convert-to'
}
