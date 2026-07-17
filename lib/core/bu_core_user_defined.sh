if false; then
source ../../bu_custom_source.sh
source ../../bu_user_defined_decl.sh
fi

# ```
# *Description*:
# Sources user defined configuration callback scripts.
#
# *Params*: None
#
# *Returns*: None
# ```
bu_source_user_defined_configs()
{
    bu_source_multi_once "${BU_USER_DEFINED_STATIC_CONFIGS[@]}"
    bu_source_multi "${BU_USER_DEFINED_DYNAMIC_CONFIGS[@]}"
}

# ```
# *Description*:
# Sources user defined pre-init callback scripts.
#
# *Params*: None
#
# *Returns*: None
# ```
bu_source_user_defined_pre_init_callbacks()
{
    bu_source_multi_once "${BU_USER_DEFINED_STATIC_PRE_INIT_ENTRYPOINT_CALLBACKS[@]}"
    bu_source_multi "${BU_USER_DEFINED_DYNAMIC_POST_ENTRYPOINT_CALLBACKS[@]}"
}

# ```
# *Description*:
# Sources user defined post-init callback scripts.
#
# *Params*: None
#
# *Returns*: None
# ```
bu_source_user_defined_post_entrypoint_callbacks()
{
    bu_source_multi_once "${BU_USER_DEFINED_STATIC_POST_ENTRYPOINT_CALLBACKS[@]}"
    bu_source_multi "${BU_USER_DEFINED_DYNAMIC_POST_ENTRYPOINT_CALLBACKS[@]}"
}

# ```
# *Params*
# - `$1`: Command to convert to a key
#
# *Returns*
# - `$BU_RET`: Key. By default it will be of the form `command-$1`, but users can override the behavior with user defined functions in `${BU_USER_DEFINED_COMPLETION_COMMAND_TO_KEY_CONVERSIONS[@]}`.
#              The first user defined function to perform the conversion successfully will take priority.
#
# Each function will be of the following signature
# *Function Params*
# - `$1`: Command to convert to a key
#
# *Function Returns*
# - Exit code:
#   - 0: Function successfully maps command to a key
#   - 1 or any other non-zero exit code: Mapping is unsuccessful
# - `$BU_RET`: If exit code is 0, then this should be the key
# ```
bu_user_defined_convert_command_to_key()
{
    local command=$1
    local fn
    for fn in "${BU_USER_DEFINED_COMPLETION_COMMAND_TO_KEY_CONVERSIONS[@]}"
    do
        "$fn" "$command"
        if (($? == 0))
        then
            return
        fi
    done
    BU_RET=command-$command # default conversion
}

# ```
# *Params*
# - `...`: Lazy autocompletion args
#
# *Returns*
# - `${COMPREPLY[@]}`: Original contents plus new autocompletions
# - `$BU_RET`: Number of lazy autocompletion args consumed
#
# Each function will be of the following signature
# *Function Params*
# - `...`: Lazy autocompletion args
#
# *Function Returns*
# - Exit code:
#   - 0: Function successfully parses the lazy autocompletion args
#   - 124: Function successfully parses the lazy autocompletion args,
#          needs to await further input from user and retry before moving on to the next word.
#   - 1: Function does not handle the lazy autocompletion args
# - `${COMPREPLY[@]}`: If exit code is 0, then this is the original contents plus new autocompletions
# - `$BU_RET`: If exit code is 0, then this should be the number of lazy autocompletion args consumed
# ```
bu_user_defined_autocomplete_lazy()
{
    local fn
    local exit_code=1
    local fn_exit_code
    BU_RET=0
    for fn in "${BU_USER_DEFINED_AUTOCOMPLETE_HELPERS[@]}"
    do
        "$fn" "$@"
        fn_exit_code=$?
        case "$fn_exit_code" in
        0|124)
            exit_code=$fn_exit_code
            break
            ;;
        1|*)
            continue
            ;;
        esac
    done
    return "$exit_code"
}

# ```
# *Description*:
# Register a module with BashTab's module registry.
# Modules call this to self-identify with a name and optional version,
# enabling bu module-list and other inspection commands.
#
# *Params*:
# - `$1`: Module name (e.g. "utilities", "demoapp")
# - `$2`: Module version (e.g. "0.1.0", or empty string)
# - `$3`: Path to the module's preinit callback script
#
# *Side effects*:
# - Registers the module in BU_MODULE_REGISTRY (associative array)
# - Appends the preinit callback to BU_USER_DEFINED_STATIC_PRE_INIT_ENTRYPOINT_CALLBACKS
# ```
__bu_module_register()
{
    local name=$1
    local version=$2
    local preinit=$3

    if [[ -z "${BU_MODULE_REGISTRY[$name]}" ]]; then
        BU_MODULE_REGISTRY[$name]="$version:$preinit"
    fi
    # Also build an exportable scalar for subshell inspection
    if [[ "$BU_MODULE_LIST" != *"${name}:"* ]]; then
        BU_MODULE_LIST+="${name}:${version}:${preinit};"
    fi
    BU_USER_DEFINED_STATIC_PRE_INIT_ENTRYPOINT_CALLBACKS+=("$preinit")
}
