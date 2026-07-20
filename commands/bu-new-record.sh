#!/usr/bin/env bash
function __bu_bu_new_record_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local -a pairs=()
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
    *)
        pairs+=("$1")
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
Construct a single JSON record from key=value pairs (PowerShell
[PSCustomObject]@{...}). Values are properly JSON-escaped.
Use key:=value for typed JSON values (numbers, booleans, arrays).

Prefer bu_out_from_tsv / bu convert-from-tsv when constructing many
records in a loop: one jq process for the whole stream instead of one
per record.
" \
        --example "Simple record" "name=bashtab version=0.1.0" \
        --example "Typed values" "pid=$$ alive:=true retries:=3"
    return 0
fi

bu_out_record "${pairs[@]}"

bu_scope_pop_function
}

__bu_bu_new_record_main "$@"
