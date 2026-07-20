#!/usr/bin/env bash
function __bu_bu_get_module_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local format=auto
local columns=
local is_help=false
local error_msg=
local options_finished=false
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --format)# FORMAT
        # Output format
        bu_parse_positional $# --enum $BU_OUT_FORMATS enum-- --hint "Output format"
        bu_validate_positional "${!shift_by}"
        format=${!shift_by}
        ;;
    --columns)# COLUMNS
        # Fields to display, in order (comma-separated)
        bu_parse_positional $# --enum name version path enum-- --hint "Comma-separated fields"
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
List all modules registered via __bu_module_register.
Reads the BU_get_module environment variable (populated when modules
are sourced at shell startup). Modules that were loaded without calling
__bu_module_register (legacy BU_MODULE_PATH entries) are shown with
version \"-\" and a note.

Output is structured: piped output defaults to JSONL, terminal output
defaults to a table. Use --format to override.
" \
        --example "List modules" "" \
        --example "List modules as a JSON array" "--format json" \
        --example "List modules as a list" "--format list"
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

if ((${#entries[@]} == 0))
then
    # Hints go to stderr so they never pollute the structured stream
    bu_log_info "No modules registered."
    bu_log_info "Modules are detected via __bu_module_register in their module script."
    bu_log_info "Use 'bu new-module --name <name>' to scaffold a properly registered module."
else
    # Stream TSV records (zero forks in the loop), recordify once, then
    # let bu_out decide presentation (table on a terminal, JSONL when piped)
    local entry
    {
        for entry in "${entries[@]}"
        do
            [[ -z "$entry" ]] && continue
            local name=${entry%%:*}
            local rest=${entry#*:}
            local version=${rest%%:*}
            local path=${rest#*:}
            printf '%s\t%s\t%s\n' "$name" "$version" "$path"
        done
    } | bu_out_from_tsv --columns name,version,path | bu_out --format "$format" ${columns:+--columns "$columns"}
fi

bu_scope_pop_function
}

__bu_bu_get_module_main "$@"
