#!/usr/bin/env bash
# Synopsis: Show bash shell options (set -o)
function __bu_bu_get_shell_option_main()
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
            # Name positional: complete from set -o option names
            autocompletion=(--ret __bu_bu_shell_option_complete_names ret-- --hint "Option name")
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
List set -o shell options as records (the $ErrorActionPreference-style switches of bash).
Covers errexit, nounset, pipefail, xtrace, and friends; each record has
name and value (boolean). Runs in the current shell, so the values are
the live settings. Toggle them with bu set-shell-option.
" \
        --example "All options" "" \
        --example "Options currently off" "" \
        --example "One option" "pipefail"
    return 0
fi

# Runs sourced, so `set -o` reports the current shell's live settings
set -o | jq -R -c --arg name "$name" '
    select(. != "")
    | capture("^(?<name>\\S+)\\s+(?<value>on|off)$")
    | select($name == "" or .name == $name)
    | .value |= (. == "on")
' | bu_out --format "$format"

bu_scope_pop_function
}

# Completion helper: valid set -o option names (shared with set-shell-option).
__bu_bu_shell_option_complete_names()
{
    BU_RET=()
    local o
    while IFS= read -r o
    do
        [[ -n "$o" ]] && BU_RET+=("$o")
    done < <(set -o | awk '{print $1}')
}

__bu_bu_get_shell_option_main "$@"
