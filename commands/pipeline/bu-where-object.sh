#!/usr/bin/env bash
function __bu_bu_where_object_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local expression=
local format=auto
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --format)# FORMAT
        # Output format
        bu_parse_positional $# --enum ${BU_OUT_FORMATS[@]} enum-- --hint "Output format"
        format=${!shift_by}
        ;;

    -h|--help)# _FLAG
        # Print help
        is_help=true
        ;;
    *)
        if bu_env_is_in_autocomplete && [[ "$1" != -* ]]
        then
            # Bare positional: suggest jq-style fields of the pipeline producer's records
            autocompletion=(--ret __bu_out_complete_pipeline_fields --dot ret-- --hint "jq field (from pipeline producer)")
        fi
        if [[ -z "$expression" ]]
        then
            expression=$1
        else
            bu_parse_error_enum "$1"
        fi
        ;;
    esac
    if "$is_help"
    then
        break
    fi
    if (( $# < shift_by ))
    then
        bu_parse_error_argn "$1" $#
        break
    fi
    shift "$shift_by"
done
local remaining_options=("$@")
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi

if "$is_help"
then
    bu_autohelp \
        --description "
Filter a JSONL stream with a jq boolean expression (PowerShell Where-Object).
Reads records from stdin; records where the expression is truthy pass through.
The current record is '.' in the expression. Streams with O(1) latency.
" \
        --example "Only source commands" "'.type == \"source\"'" \
        --example "Match a pattern" "'.name | test(\"^get-\")'"
    return 0
fi

if [[ -z "$expression" ]]
then
    error_msg="Missing required jq expression (e.g. bu where-object '.type == \"source\"')"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

# Cmdlets implicitly end at Out-Default: a table on a terminal, JSONL when piped
bu_out_where "$expression" | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_where_object_main "$@"
