# bash-ide source=../../bu_custom_source.sh
# bash-ide source=../../bu_user_defined_decl.sh

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
    local -r saved_module=${BU_CURRENT_MODULE:-}
    local filepath
    if ! "$BU_SOURCE_IS_CUSTOM" && ((${#BU_USER_DEFINED_STATIC_PRE_INIT_ENTRYPOINT_CALLBACKS[@]}))
    then
        for filepath in "${BU_USER_DEFINED_STATIC_PRE_INIT_ENTRYPOINT_CALLBACKS[@]}"
        do
            BU_CURRENT_MODULE=${BU_MODULE_PREINIT_MAP[$filepath]:-}
            # shellcheck disable=SC1090
            source "$filepath"
        done
    else
        for filepath in "${BU_USER_DEFINED_STATIC_PRE_INIT_ENTRYPOINT_CALLBACKS[@]}"
        do
            BU_CURRENT_MODULE=${BU_MODULE_PREINIT_MAP[$filepath]:-}
            # shellcheck disable=SC1090
            source "$filepath" --__bu-once --__bu-no-inline
        done
    fi
    BU_CURRENT_MODULE=$saved_module
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
        "$fn" "$@" && fn_exit_code=0 || fn_exit_code=$?
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
# Parse BU_MODULE_LIST and register preinit callbacks + module registry entries.
#
# BU_MODULE_LIST is an exported scalar of the form:
#   "name:version:preinit_path;name:version:preinit_path;..."
#
# Modules append to it in their module script; the top-level sets it directly.
# Top-level projects set it directly in their activate script before sourcing
# bu_entrypoint.sh — no function call needed.
#
# *Side effects*:
# - Populates BU_MODULE_REGISTRY (for bu get-module)
# - Appends preinit paths to BU_USER_DEFINED_STATIC_PRE_INIT_ENTRYPOINT_CALLBACKS
# ```
__bu_parse_module_list()
{
    local entry name version path
    local old_ifs=$IFS
    IFS=';'
    local -a entries=()
    entries=(${BU_MODULE_LIST:-})
    IFS=$old_ifs

    local -A seen_names=()
    local -A seen_paths=()
    local deduped=
    BU_MODULE_PREINIT_MAP=()

    for entry in "${entries[@]}"
    do
        [[ -z "$entry" ]] && continue
        name=${entry%%:*}
        local rest=${entry#*:}
        version=${rest%%:*}
        path=${rest#*:}

        # Dedup by name (first registration wins)
        if [[ -n "${seen_names[$name]:-}" ]]; then
            continue
        fi
        seen_names[$name]=1

        # Precedence rank: 1-based position in the deduped list (top-level=1,
        # dependencies in list order). First assignment wins so re-activation
        # cannot renumber an already-ranked module.
        if [[ -z "${BU_MODULE_RANK[$name]:-}" ]]; then
            BU_MODULE_RANK[$name]=${#seen_names[@]}
        fi

        # Append to deduped list
        deduped+="${name}:${version}:${path};"

        # Register for bu get-module
        BU_MODULE_REGISTRY[$name]="$version:$path"

        # Register preinit callback (dedup by path)
        if [[ -n "$path" && -z "${seen_paths[$path]:-}" ]]; then
            seen_paths[$path]=1
            BU_USER_DEFINED_STATIC_PRE_INIT_ENTRYPOINT_CALLBACKS+=("$path")
            BU_MODULE_PREINIT_MAP[$path]=$name
        fi
    done

    # Write back the deduped list
    BU_MODULE_LIST=$deduped
    export BU_MODULE_LIST
}
