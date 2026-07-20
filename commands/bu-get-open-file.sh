#!/usr/bin/env bash
function __bu_bu_get_open_file_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    -h|--help)# _FLAG
        is_help=true
        ;;
    *)
        # Any unrecognized arg: pass through to the underlying command, replacing the default
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
        --description "List open files (jc lsof parser wrapper)." \
        --example "Default" "" \
        --example "With extra flags" "-- -la /var/log"
    return 0
fi

if ! command -v jc &>/dev/null
then
    error_msg="jc is required. Install with: pip install jc"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

# Build the command: use provided args if any, otherwise the default
local -a cmd=()
if ((${#remaining_options[@]} > 0))
then
    cmd=("${remaining_options[@]}")
else
    cmd=(lsof)
fi

"${cmd[@]}" 2>/dev/null | jc --lsof 2>/dev/null | jq -c 'if type == "array" then .[] else . end' 2>/dev/null | bu_out

bu_scope_pop_function
}

__bu_bu_get_open_file_main "$@"
