#!/usr/bin/env bash
function __bu_bu_get_module_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local is_json=false
local is_help=false
local error_msg=
local options_finished=false
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --json)# _FLAG
        # Output module list as JSON
        is_json=true
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
List all modules registered via __bu_module_register.
Reads the BU_get_module environment variable (populated when modules
are sourced at shell startup). Modules that were loaded without calling
__bu_module_register (legacy BU_MODULE_PATH entries) are shown with
version \"-\" and a note.
" \
        --example "List modules" "" \
        --example "List modules as JSON" "--json"
    return 0
fi

# Parse BU_MODULE_LIST: "name:version:path;name:version:path;..."
local -a entries=()
if [[ -n "$BU_MODULE_LIST" ]]; then
    local _ifs=$IFS
    IFS=';'
    entries=($BU_MODULE_LIST)
    IFS=$_ifs
fi

if "$is_json"
then
    printf '{\n'
    local first=true
    local entry
    for entry in "${entries[@]}"
    do
        [[ -z "$entry" ]] && continue
        "$first" || printf ',\n'
        first=false
        local name=${entry%%:*}
        local rest=${entry#*:}
        local version=${rest%%:*}
        local path=${rest#*:}
        printf '  "%s": {"version": "%s", "path": "%s"}' "$name" "$version" "$path"
    done
    printf '\n}\n'
else
    if ((${#entries[@]} == 0))
    then
        echo "No modules registered."
        echo "Modules are detected via __bu_module_register in their module script."
        echo "Use 'bu new-module --name <name>' to scaffold a properly registered module."
    else
        local g=$BU_TPUT_GREEN b=$BU_TPUT_BOLD rs=$BU_TPUT_RESET yl=$BU_TPUT_VSCODE_YELLOW
        printf '%-20s %-10s %s\n' "${b}NAME${rs}" "${b}VERSION${rs}" "${b}PATH${rs}"
        printf '%-20s %-10s %s\n' '--------------------' '----------' '--------------------'
        local entry
        for entry in "${entries[@]}"
        do
            [[ -z "$entry" ]] && continue
            local name=${entry%%:*}
            local rest=${entry#*:}
            local version=${rest%%:*}
            local path=${rest#*:}
            local display_path=$path
            local max_path=60
            if ((${#display_path} > max_path))
            then
                display_path="...${display_path:${#display_path}-max_path+3}"
            fi
            printf '%-20s %-10s %s\n' "${g}${name}${rs}" "${yl}${version}${rs}" "$display_path"
        done
    fi
fi

bu_scope_pop_function
}

__bu_bu_get_module_main "$@"
