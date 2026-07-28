#!/usr/bin/env bash
function __bu_bu_get_shopt_option_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local name=
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
            # Name positional: complete from shopt option names
            autocompletion=(--ret __bu_bu_shopt_complete_names ret-- --hint "Option name")
        fi
        if [[ -z "$name" ]]
        then
            name=$1
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
List shopt shell options as records (bash's extended behavior switches).
Covers globstar, nullglob, dotglob, autocd, extglob, and ~50 more; each
record has name and value (boolean). Runs in the current shell, so the
values are the live settings. Toggle them with bu set-shopt-option.
" \
        --example "All options" "" \
        --example "What is on right now" "" \
        --example "One option" "globstar"
    return 0
fi

# Runs sourced, so `shopt` reports the current shell's live settings
shopt | jq -R -c --arg name "$name" '
    select(. != "")
    | capture("^(?<name>\\S+)\\s+(?<value>on|off)$")
    | select($name == "" or .name == $name)
    | .value |= (. == "on")
' | bu_out --format "$format"

bu_scope_pop_function
}

# Completion helper: valid shopt option names (shared with set-shopt-option).
__bu_bu_shopt_complete_names()
{
    BU_RET=()
    local o
    while IFS= read -r o
    do
        [[ -n "$o" ]] && BU_RET+=("$o")
    done < <(shopt | awk '{print $1}')
}

__bu_bu_get_shopt_option_main "$@"
