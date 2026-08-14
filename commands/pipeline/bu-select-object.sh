#!/usr/bin/env bash
# Dispatch: source
# Synopsis: Project JSONL records to a subset of fields
function __bu_bu_select_object_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local fields=
local format=auto
local is_unique=false
local is_expand=false
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    -h|--help)# _FLAG
        # Print help
        is_help=true
        ;;
    --unique)# _FLAG
        # Deduplicate records after projection (first occurrence wins)
        is_unique=true
        ;;
    --expand)# _FLAG
        # Lift a single nested object field to top level
        is_expand=true
        ;;
    --format)# FORMAT
        # Output format
        bu_parse_positional $# --enum ${BU_OUT_FORMATS[@]} enum-- --hint "Output format"
        format=${!shift_by}
        ;;
    *)
        if bu_env_is_in_autocomplete && [[ "$1" != -* ]]
        then
            # Bare positional: suggest fields of the pipeline producer's records
            autocompletion=(--hint "field" --pipeline-fields pipeline-fields--)
        fi
        if [[ -z "$fields" ]]
        then
            fields=$1
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
Project a JSONL stream to a subset of fields (PowerShell Select-Object).
Reads records from stdin. Fields are emitted in the specified order;
'new=old' renames a field. Missing fields are emitted as null.
--unique deduplicates records after projection (first occurrence wins).
" \
        --example "Keep two fields" "name,version" \
        --example "Rename a field" "name,ver=version" \
        --example "Select unique values" "--unique verb" \
        --example "Flatten a nested object" "--expand server" \
        --example "Output as JSON array" "name,version --format json"
    return 0
fi

if [[ -z "$fields" ]]
then
    error_msg="Missing required field spec (e.g. bu select-object name,ver=version)"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

# Cmdlets implicitly end at Out-Default: a table on a terminal, JSONL when piped
local -a select_args=()
"$is_unique" && select_args+=(--unique)
"$is_expand" && select_args+=(--expand)
select_args+=("$fields")
bu_out_select "${select_args[@]}" | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_select_object_main "$@"
