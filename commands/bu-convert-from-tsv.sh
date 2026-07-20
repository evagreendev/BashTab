#!/usr/bin/env bash
function __bu_bu_convert_from_tsv_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local columns=
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --columns)# COLUMNS
        # Column names assigned to TSV fields in order (comma-separated)
        bu_parse_positional $# --hint "Comma-separated columns (e.g. name,version,path)"
        columns=${!shift_by}
        ;;
    -h|--help)# _FLAG
        # Print help
        is_help=true
        ;;
    *)
        bu_parse_error_enum "$1"
        break
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
Convert a TSV stream to JSONL records (PowerShell ConvertFrom-Csv).
Fields without a column are dropped; missing trailing fields leave keys
absent; blank lines are skipped. One jq process for the whole stream.
" \
        --example "Recordify TSV" "--columns name,version,path"
    return 0
fi

if [[ -z "$columns" ]]
then
    error_msg="Missing required --columns (e.g. bu convert-from-tsv --columns name,version)"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

bu_out_from_tsv --columns "$columns"

bu_scope_pop_function
}

__bu_bu_convert_from_tsv_main "$@"
