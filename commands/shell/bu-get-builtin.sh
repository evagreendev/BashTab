#!/usr/bin/env bash
function __bu_bu_get_builtin_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local filter=
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
        if [[ -z "$filter" ]]
        then
            filter=$1
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
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi

if "$is_help"
then
    bu_autohelp \
        --description "
List bash builtins with their enabled status (structured enable -a).
Each record: name, enabled (boolean). Builtins disabled with 'enable -n'
show as false. Give a glob to filter by name. See also bu get-command
for BashTab commands and bu get-alias for aliases.
" \
        --example "All builtins" "" \
        --example "One builtin" "printf"
    return 0
fi

# enable -a prints 'enable NAME' or 'enable -n NAME' (disabled)
enable -a | jq -R -c --arg filter "$filter" '
    select(. != "")
    | if startswith("enable -n ")
      then {name: .[10:], enabled: false}
      else sub("^enable "; "") | {name: ., enabled: true}
      end
    | select($filter == "" or (.name | test($filter)))
' | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_get_builtin_main "$@"
