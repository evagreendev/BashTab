#!/usr/bin/env bash
function __bu_bu_set_location_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local module_name=
local commands_dir=
local is_cache=false
local is_bash_tab=false
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --module)# MODULE_NAME
        # Root directory of a loaded module (default: current top-level)
        bu_parse_positional $# --hint "Module name (empty for top-level)"
        module_name=${!shift_by}
        ;;
    --commands-dir)# COMMANDS_DIR
        # A registered command-search directory
        bu_parse_positional $# --hint "Path to a commands directory"
        commands_dir=${!shift_by}
        ;;
    --cache)# _FLAG
        # BashTab cache directory
        is_cache=true
        ;;
    --bash-tab)# _FLAG
        # BashTab installation root (BU_DIR)
        is_bash_tab=true
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

if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi

if "$is_help"
then
    bu_autohelp --description "
Change the current working directory to a well-known project location.

Runs in the current shell (sourceable command) so cd takes effect.
Equivalent to PowerShell's Set-Location.
" \
    --example "Jump to the top-level module root" "--module" \
    --example "Jump to a specific module" "--module mylib" \
    --example "Jump to a commands directory" "--commands-dir /path/to/commands" \
    --example "Jump to the cache directory" "--cache"
    return 0
fi

local dir=

if [[ -n "$commands_dir" ]]; then
    # Validate it's a registered command-search directory
    if [[ -z "${BU_COMMAND_SEARCH_DIRS[$commands_dir]:-}" ]]; then
        bu_log_err "Not a registered command-search directory: $commands_dir"
        bu_log_info "Registered directories:"
        local d
        for d in "${!BU_COMMAND_SEARCH_DIRS[@]}"; do
            bu_log_info "  $d"
        done
        return 1
    fi
    dir=$commands_dir
elif [[ -n "$module_name" || ( -z "$module_name" && ! "$is_cache" && ! "$is_bash_tab" ) ]]; then
    # --module with optional name, or default when no flag given
    local key=${module_name:-${BU_TOP_LEVEL_MODULE:-}}
    if [[ -z "$key" ]]; then
        bu_log_err "No module specified and BU_TOP_LEVEL_MODULE is not set"
        return 1
    fi
    local entry=${BU_MODULE_REGISTRY[$key]:-}
    if [[ -z "$entry" ]]; then
        bu_log_err "Module '$key' not found in BU_MODULE_REGISTRY"
        local mod
        bu_log_info "Loaded modules:"
        for mod in "${!BU_MODULE_REGISTRY[@]}"; do
            bu_log_info "  $mod"
        done
        return 1
    fi
    # entry format: "version:preinit_path"
    dir=$(dirname -- "${entry#*:}")
elif "$is_cache"; then
    dir=$BU_CACHE_DIR
elif "$is_bash_tab"; then
    dir=$BU_DIR
fi

if [[ -z "$dir" ]]; then
    bu_log_err "Specify a location: --module, --commands-dir, --cache, or --bash-tab"
    return 1
fi

if [[ ! -d "$dir" ]]; then
    bu_log_err "Directory does not exist: $dir"
    return 1
fi

cd "$dir" || return 1
bu_log_info "Now in $dir"

bu_scope_pop_function
}

__bu_bu_set_location_main "$@"
