#!/usr/bin/env bash
function __bu_bu_sort_object_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local key=
local is_desc=false
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --desc)# _FLAG
        # Sort descending
        is_desc=true
        ;;
    -h|--help)# _FLAG
        # Print help
        is_help=true
        ;;
    *)
        if [[ -z "$key" ]]
        then
            key=$1
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
Sort a JSONL stream by a field (PowerShell Sort-Object).
Reads records from stdin. Buffers all input.
Ordering: null < false < true < numbers < strings < arrays < objects.
" \
        --example "Sort by noun" "noun" \
        --example "Descending" "name --desc"
    return 0
fi

if [[ -z "$key" ]]
then
    error_msg="Missing required field to sort by (e.g. bu sort-object name)"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

local -a sort_args=("$key")
"$is_desc" && sort_args+=(--desc)
bu_out_sort_by "${sort_args[@]}"

bu_scope_pop_function
}

__bu_bu_sort_object_main "$@"
