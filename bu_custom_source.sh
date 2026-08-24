# This file does not depend on any other file in BashTab, because we need to 
# define a custom source func ahead of other functions
# e.g. to ensure the correctness of --__bu-once

# ```
# The bu repo base directory
# ```
export BU_DIR=$PWD
# ```
# The directory where non user defined executables are placed
# ```
BU_LIB_BIN_DIR=$BU_DIR/lib/bin
# ```
# The directory where non user defined sourceable shell scripts are placed
# ```
BU_LIB_BINSRC_DIR=$BU_DIR/lib/binsrc
# ```
# The directory of the core library
# ```
BU_LIB_CORE_DIR=$BU_DIR/lib/core

BU_LIB_TEMPLATE_DIR=$BU_DIR/lib/templates

BU_BUILTIN_COMMANDS_DIR=$BU_DIR/commands


# ```
# Traditionally, bash has 3 states for a scalar variable
# 1. Undefined: `[[ ! -v VAR ]]` will be true
# 2. Empty: `[[ -v VAR && -z "$VAR" ]]` will be true
# 3. Non-empty: `[[ -n "$VAR" ]]` will be true
#
# However, state 1 isn't that useful if we want to "forward declare" a variable an initialize it to empty
# effectively, we only have states 2 and 3. Thus when we need 3 states (or if empty is considered to be a valid input),
# then we will use the following instead:
# 1. NULL: `bu_is_null "$VAR"` will be true
# 2. Empty: Same as above
# 3. Non-empty: Same as above
# ```
BU_NULL=BU_NULL

# ```
# *Description*:
# Log a message with a given log level prefix
#
# *Params*:
# - `$1`: log level prefix (e.g., DEBUG, INFO, WARN, ERR)
# - `...`: message to log
#
# *Examples*:
# ```bash
# __bu_basic_log INFO "This is an info message"
# ```
# ```
__bu_basic_log()
{
    local log_prefix=$1
    shift
    printf -v log_prefix '%-7s' "$log_prefix"
    printf '%s %s\n' "$log_prefix" "$*" >&2
}

# ```
# *Description*:
# Log a debug message
#
# *Params*:
# - `...`: message to log
# ```
bu_basic_log_debug()
{
    # Bootstrap debug logs (e.g. "sourcing(--__bu-once) ...") fire before the
    # repo configs are loaded, so they gate on a dedicated boolean rather than
    # BU_LOG_LVL. Enable via `bu set-config BU_BOOTSTRAP_VERBOSE true`.
    [[ "${BU_BOOTSTRAP_VERBOSE:-false}" == true ]] || return 0
    __bu_basic_log DEBUG "$*"
}

# ```
# *Description*:
# Log an info message
#
# *Params*:
# - `...`: message to log
# ```
bu_basic_log_info()
{
    __bu_basic_log INFO "$*"
}

# ```
# *Description*:
# Log a warning message
#
# *Params*:
# - `...`: message to log
# ```
bu_basic_log_warn()
{
    __bu_basic_log WARN "$*"
}

# ```
# *Description*:
# Log an error message
#
# *Params*:
# - `...`: message to log
# ```
bu_basic_log_err()
{
    __bu_basic_log ERR "$*"
}

# MARK: Config registry

# Declarative settings registry — the config equivalent of the autocompletion
# DSL specifiers. One `bu_config_register` call declares everything about a
# setting; `bu set-config` (validation, value mapping, --unset default restore,
# --list, completion) consumes the registry. Modules can register their own
# settings the same way.
#
# Acceptable setting-name prefixes. Embedders can pre-seed this array before
# sourcing the entrypoint or append to it afterward to allow their own
# namespaced settings (e.g. BU_CONFIG_NAME_PREFIXES+=(MYAPP_)).
# Declared guarded so a pre-seeded value survives.
if ! declare -p BU_CONFIG_NAME_PREFIXES &>/dev/null
then
    declare -a -g BU_CONFIG_NAME_PREFIXES=(BU_)
fi

# Storage mirrors BU_COMMAND_PROPERTIES: keys are "$name,field".
declare -A -g BU_CONFIG_PROPERTIES=()

# Named persistence layers. Each entry maps a layer name to a resolver
# function that prints the layer's settings file path for the current context.
# The "local" layer is built-in (the machine-local settings file).
declare -A -g BU_CONFIG_LAYER_RESOLVERS=()

# ```
# *Description*:
# Validate a setting name against the configured name prefixes.
# Returns 0 if the name starts with one of the prefixes listed in
# BU_CONFIG_NAME_PREFIXES and contains only uppercase letters, digits,
# and underscores after the prefix.
#
# *Params*:
# - `$1`: Setting name to validate
#
# *Returns*:
# - 0 if the name is valid, 1 otherwise
# ```
bu_config_name_is_valid()
{
    local -r name=$1
    local prefix
    for prefix in "${BU_CONFIG_NAME_PREFIXES[@]}"
    do
        if [[ "$name" =~ ^${prefix}[A-Z0-9_]*$ ]]
        then
            return 0
        fi
    done
    return 1
}

# ```
# *Description*:
# Register a named persistence layer with a resolver function.
# The resolver is called by bu_config_layer_file and should print
# the layer's settings file path to stdout for the current context.
#
# *Params*:
# - `$1`: Layer name (must be usable as a shell identifier)
# - `$2`: Resolver function name (called with any extra args passed to
#   bu_config_layer_file)
# ```
bu_config_register_layer()
{
    local name=$1
    local resolver=$2
    BU_CONFIG_LAYER_RESOLVERS[$name]=$resolver
    return 0
}

# ```
# *Description*:
# Resolve a named layer to its settings file path.
# The "local" layer (and empty name) resolve to the machine-local file.
#
# *Params*:
# - `$1`: Layer name (`local` or a registered layer)
# - `...`: Extra arguments forwarded to the layer's resolver function
#
# *Returns*:
# - `BU_RET`: the resolved file path
# - Exit code: 0 on success, 1 if the layer name is unknown
# ```
bu_config_layer_file()
{
    local name=$1
    shift
    if [[ -z "$name" || "$name" == local ]]
    then
        BU_RET=${BU_CONFIG_LOCAL_FILE:-"$BU_DIR"/config/bu_config_local.sh}
        return 0
    fi
    local resolver=${BU_CONFIG_LAYER_RESOLVERS[$name]:-}
    if [[ -z "$resolver" ]]
    then
        local -a names=(local)
        local k
        for k in "${!BU_CONFIG_LAYER_RESOLVERS[@]}"
        do
            [[ -n "${BU_CONFIG_LAYER_RESOLVERS[$k]}" ]] && names+=("$k")
        done
        printf -v _joined '%s, ' "${names[@]}"
        bu_log_err "Unknown config layer '$name'. Registered layers: ${_joined%, }"
        return 1
    fi
    BU_RET=$("$resolver" "$@")
    return 0
}

# ```
# *Description*:
# Register a runtime setting with metadata.
#
# *Params*:
# - `$1`: Setting name (must start with one of the configured prefixes)
# - `...`: DSL specifiers, processed left to right:
#   - `--default VALUE`: value restored by `bu set-config --unset`
#   - `--bool`: value must be `true` or `false`
#   - `--enum a b:2 c enum--`: allowed values; optional `name:mapped` form
#     accepts `name` but stores `mapped` (e.g. warn:2)
#   - `--hint "text"`: description shown by `bu set-config --list`
#
# *Examples*:
# ```bash
# bu_config_register BU_LOG_LVL --default 2 \
#     --enum debug:0 info:1 warn:2 err:3 silence:99 enum-- \
#     --hint "Log level when running commands"
# ```
# ```
bu_config_register()
{
    local name=$1
    shift
    if ! bu_config_name_is_valid "$name"
    then
        local _prefix_list="${BU_CONFIG_NAME_PREFIXES[*]}"
        bu_basic_log_err "bu_config_register: invalid setting name[$name], must match ^(${_prefix_list// /|})[A-Z0-9_]*$"
        return 1
    fi
    local default= enum= hint= layer= complete_values_fn=
    local is_bool=false
    local presets=
    while (($#))
    do
        case "$1" in
        --default)
            default=$2
            shift 2
            ;;
        --bool)
            is_bool=true
            shift
            ;;
        --enum)
            shift
            local -a enum_values=()
            while (($#)) && [[ "$1" != enum-- ]]
            do
                enum_values+=("$1")
                shift
            done
            if (($# == 0))
            then
                bu_basic_log_err "bu_config_register: --enum missing terminator enum--"
                return 1
            fi
            shift
            enum="${enum_values[*]}"
            ;;
        --presets)
            shift
            local -a preset_values=()
            while (($#)) && [[ "$1" != presets-- ]]
            do
                preset_values+=("$1")
                shift
            done
            if (($# == 0))
            then
                bu_basic_log_err "bu_config_register: --presets missing terminator presets--"
                return 1
            fi
            shift
            presets="${preset_values[*]}"
            ;;
        --complete-values)
            complete_values_fn=$2
            shift 2
            ;;
        --layer)
            layer=$2
            shift 2
            ;;
        --hint)
            hint=$2
            shift 2
            ;;
        *)
            bu_basic_log_err "bu_config_register: unrecognized specifier[$1]"
            return 1
            ;;
        esac
    done
    BU_CONFIG_PROPERTIES[$name,registered]=true
    [[ -n "$default" ]] && BU_CONFIG_PROPERTIES[$name,default]=$default
    [[ -n "$enum" ]] && BU_CONFIG_PROPERTIES[$name,enum]=$enum
    [[ -n "$hint" ]] && BU_CONFIG_PROPERTIES[$name,hint]=$hint
    [[ -n "$presets" ]] && BU_CONFIG_PROPERTIES[$name,presets]=$presets
    "$is_bool" && BU_CONFIG_PROPERTIES[$name,bool]=true
    [[ -n "$layer" ]] && BU_CONFIG_PROPERTIES[$name,layer]=$layer
    [[ -n "$complete_values_fn" ]] && BU_CONFIG_PROPERTIES[$name,complete_values_fn]=$complete_values_fn
    # Stamp the owning module (mirrors __bu_stamp_command_module and the
    # help-topic stamp in bu_core_help_topic.sh) so `bu get-config` can tell
    # a core BU_* setting from one a module registered. STICKY: only
    # overwrite when BU_CURRENT_MODULE is non-empty. Rationale:
    # `bu set-config --unset` for a setting without a registered default
    # re-sources config/bu_config_dynamic.sh outside the entrypoint, where
    # BU_CURRENT_MODULE is empty — an unconditional stamp would blank every
    # core setting's provenance on that path.
    if [[ -n "${BU_CURRENT_MODULE:-}" ]]
    then
        BU_CONFIG_PROPERTIES[$name,module]=$BU_CURRENT_MODULE
    fi
    return 0
}

# ```
# *Description*:
# Validate a value against a registered setting and map it to its stored form.
# Unregistered settings (or registered ones without --bool/--enum) pass through.
#
# *Params*:
# - `$1`: Setting name
# - `$2`: Candidate value
#
# *Returns*:
# - `BU_RET`: the value to store (mapped form for name:mapped enum entries)
# - Exit code: 0 if valid, 1 if rejected
# ```
bu_config_validate_value()
{
    local name=$1 value=$2
    if [[ "${BU_CONFIG_PROPERTIES[$name,bool]:-}" == true ]]
    then
        case "$value" in
        true|false) BU_RET=$value; return 0 ;;
        *) BU_RET="expected true|false"; return 1 ;;
        esac
    fi
    local enum=${BU_CONFIG_PROPERTIES[$name,enum]:-}
    if [[ -n "$enum" ]]
    then
        local entry entry_name
        for entry in $enum
        do
            entry_name=${entry%%:*}
            if [[ "$value" == "$entry_name" ]]
            then
                # name:mapped stores the mapped form; bare name stores itself
                BU_RET=${entry#*:}
                return 0
            fi
        done
        BU_RET="expected one of: $enum"
        return 1
    fi
    BU_RET=$value
    return 0
}

# Completion helpers (consumed by `bu set-config` via the --ret DSL specifier).
__bu_config_completion_names()
{
    local key
    BU_RET=()
    for key in "${!BU_CONFIG_PROPERTIES[@]}"
    do
        if [[ "$key" == *,registered ]]
        then
            BU_RET+=("${key%,registered}")
        fi
    done
}

__bu_config_completion_values()
{
    local name=$1
    BU_RET=()

    # Dynamic completion function takes priority over bool/enum.
    local fn=${BU_CONFIG_PROPERTIES[$name,complete_values_fn]:-}
    if [[ -n "$fn" ]]
    then
        if declare -F "$fn" &>/dev/null
        then
            # FN receives the setting name as $1, returns candidates in BU_RET.
            # Must be side-effect-free and fast (runs on every TAB).
            "$fn" "$name" || true
        fi
        return 0
    fi

    local entry
    if [[ "${BU_CONFIG_PROPERTIES[$name,bool]:-}" == true ]]
    then
        BU_RET=(true false)
        return 0
    fi
    for entry in ${BU_CONFIG_PROPERTIES[$name,enum]:-}
    do
        BU_RET+=("${entry%%:*}")
    done
    for entry in ${BU_CONFIG_PROPERTIES[$name,presets]:-}
    do
        BU_RET+=("preset:${entry}")
    done
}

# Completion helper: list registered layer names (for bu set-config --layer).
__bu_config_completion_layers()
{
    BU_RET=(local)
    local k
    for k in "${!BU_CONFIG_LAYER_RESOLVERS[@]}"
    do
        [[ -n "${BU_CONFIG_LAYER_RESOLVERS[$k]}" ]] && BU_RET+=("$k")
    done
}

# ```
# *Description*:
# Check if a variable is BU_NULL
#
# *Params*:
# - `$1`: variable to check
#
# *Returns*:
# - Returns 0 (true) if the variable is BU_NULL, else returns 1 (false)
# *Examples*:
# ```bash
# bu_is_null "$VAR"
# ```
# ```
bu_is_null()
{
    [[ "$1" = BU_NULL ]]
}

# ```
# *Description*:
# Check if a variable is BU_NULL or empty
#
# *Params*:
# - `$1`: variable to check
#
# *Returns*:
# - Returns 0 (true) if the variable is BU_NULL or empty, else returns 1 (false)
# *Examples*:
# ```bash
# bu_is_null_or_empty "$VAR"
# ```
# ```
bu_is_null_or_empty()
{
    [[ -z "$1" || "$1" = BU_NULL ]]
}

# ```
# *Description*:
# Check if a variable is not BU_NULL
#
# *Params*:
# - `$1`: variable to check
#
# *Returns*:
# - Returns 0 (true) if the variable is not BU_NULL, else returns 1 (false)
# *Examples*:
# ```bash
# bu_is_not_null "$VAR"
# ```
# ```
bu_is_not_null()
{
    [[ "$1" != BU_NULL ]]
}

# ```
# *Description*:
# Check if a variable is not BU_NULL and not empty
#
# *Params*:
# - `$1`: variable to check
#
# *Returns*:
# - Returns 0 (true) if the variable is not BU_NULL and not empty, else returns 1 (false)
# *Examples*:
# ```bash
# bu_is_not_null_or_empty "$VAR"
# ```
# ```
bu_is_not_null_or_empty()
{
    [[ -n "$1" && "$1" != BU_NULL ]]
}

# ```
# *Description*:
# Get directory name of a filepath. Similar to `dirname` except that no process is spawned.
#
# *Params*:
# - `$1`: a filepath
#
# *Returns*:
# - `$BU_RET`: directory name of the filepath
#
# *Examples*:
# ```bash
# bu_dirname /a/b/c.txt # $BU_RET=/a/b
# ```
# ```
bu_dirname()
{
    case "$1" in
    */*) BU_RET=${1%/*};;
    *) BU_RET=.;;
    esac
}

bu_pushd_current()
{
    local bash_source=$1
    bu_dirname "$bash_source"
    pushd "$BU_RET" &>/dev/null
}

# ```
# *Description*:
# Get base name of a filepath. Similar to `basename` except that no process is spawned.
#
# *Params*:
# - `$1`: a filepath
#
# *Returns*:
# - `$BU_RET`: base name of the filepath
#
# *Examples*:
# ```bash
# bu_basename /a/b/c.txt # $BU_RET=c.txt
# ```
# ```
bu_basename()
{
    case "$1" in
    */*) BU_RET=${1##*/};;
    *) BU_RET=$1;;
    esac
}

# ```
# *Description*:
# Split a string into an array by a given separator
#
# *Params*:
# - `$1`: Separator
# - `$2`: String to split
# - `$3` (optional): Name of the array to store the result in (default: `BU_RET`)
#
# *Returns*:
# - `$BU_RET` or the array named in `$3`: Array of split entries
#
# *Examples*:
# ```bash
# bu_str_split , "a,b,c" # ${BU_RET[@]}=(a b c)
# bu_str_split , "a,b,c" MY_ARR # ${MY_ARR[@]}=(a b c)
# ```
bu_str_split()
{
    local ifs=$1
    local to_split=$2
    local ret=${3:-BU_RET}
    if [[ -z "$to_split" ]]
    then
        eval "$ret"=
    else
        local IFS=$ifs
        # shellcheck disable=SC2229
        read -ra "$ret" <<< "$to_split"
    fi
}

# `declare -p` check instead of "${#BU_SOURCE_ONCE_CACHE[@]}", which errors
# under `set -u` when the array has never been declared (and would leave the
# array undeclared, turning later CACHE[$name]=true assignments into indexed
# array assignments with an arithmetic-invalid string subscript).
if ! declare -p BU_SOURCE_ONCE_CACHE &>/dev/null
then
    declare -A -g BU_SOURCE_ONCE_CACHE=(
        [BU_NULL]=true
        [bu_custom_source.sh]=true
    )
fi

# ```
# Whether the current source function is the custom one defined by bu_def_source
# ```
BU_SOURCE_IS_CUSTOM=false

BU_SOURCE_IS_FORCE=${BU_SOURCE_IS_FORCE:-false}
BU_SOURCE_IS_AUTOPUSHD=${BU_SOURCE_IS_AUTOPUSHD:-false}
BU_SOURCE_IS_INLINE=${BU_SOURCE_IS_INLINE:-false}
BU_SOURCE_INLINE_OUTPUT=${BU_SOURCE_INLINE_OUTPUT:-}

# ```
# *Description*:
# Define a custom source function that supports additional options
#
# *Params*:
# - `$1`: filepath to source
# - `--__bu-once` (Optional): Source the file only if it hasn't been sourced before
# - `--__bu-no-pushd` (Optional): Don't automatically pushd into the directory of the sourced file
# - `...`: additional arguments to pass to the sourced file
#
# *Examples*:
# ```bash
# bu_def_source
# source my_script.sh --__bu-once --__bu-no-pushd
# ```
#
# *Bug*:
# Top level `declare` (without `-g`) in a script is broken because we are inside a function
# ```
bu_def_source()
{
    # Set BU_SOURCE_IS_CUSTOM to indicate that we have defined a custom source function
    # Avoids the need to check whether "$(type -t source)" is "builtin" or "function"
    BU_SOURCE_IS_CUSTOM=true
    source()
    {
        local source_filepath=$1
        shift

        case "$source_filepath" in
        BU_NULL) return 0;;
        esac

        local is_force=
        local is_once=false
        local is_autopushed=
        local is_inline=
        local is_no_inline=false
        local inline_output=
        local shift_by
        while (($#))
        do
            shift_by=1
            case "$1" in
            --__bu-force)
                is_force=true
                ;;
            --__bu-once)
                # Source the file only if it hasn't been sourced before
                # Note that this option is more for optimization forces.
                # Try not to make this a requisite for correctness. 
                # (For e.g. we can force source by setting BU_SOURCE_IS_FORCE to true)
                is_once=true
                ;;
            --__bu-autopushd)
                is_autopushed=true
                ;;
            --__bu-no-autopushd)
                # Don't automatically pushd into the directory
                is_autopushed=false
                ;;
            --__bu-inline)
                is_inline=true
                inline_output=$(realpath -- "$2")
                shift_by=2
                ;;
            --__bu-no-inline)
                is_no_inline=true
                ;;
            --__bu-*)
                bu_basic_log_err "Unrecognized source option $1"
                return 1
                ;;
            *)
                break
                ;;
            esac
            shift "$shift_by"
        done
        local saved_is_force=$BU_SOURCE_IS_FORCE
        BU_SOURCE_IS_FORCE=${is_force:-$BU_SOURCE_IS_FORCE}
        local saved_is_autopushd=$BU_SOURCE_IS_AUTOPUSHD
        BU_SOURCE_IS_AUTOPUSHD=${is_autopushed:-$BU_SOURCE_IS_AUTOPUSHD}
        local saved_is_inline=$BU_SOURCE_IS_INLINE
        BU_SOURCE_IS_INLINE=${is_inline:-$BU_SOURCE_IS_INLINE}
        local saved_inline_output=$BU_SOURCE_INLINE_OUTPUT
        BU_SOURCE_INLINE_OUTPUT=${inline_output:-$BU_SOURCE_INLINE_OUTPUT}

        local basename
        local dirname
        case "$source_filepath" in
        */*)
            basename=${source_filepath##*/}
            dirname=${source_filepath%/*}
            ;;
        *)
            basename=$source_filepath
            dirname=.
            ;;
        esac

        if [[ "$is_inline" = true ]]
        then
            BU_SOURCE_ONCE_CACHE=()
            : >"$BU_SOURCE_INLINE_OUTPUT"
        fi

        # shellcheck disable=SC2317
        if "$is_once"
        then
            # We assume all bu source once files to be uniquely named
            if "${BU_SOURCE_ONCE_CACHE[$basename]:-false}"
            then
                if "${BU_SOURCE_IS_FORCE:-false}"
                then
                    bu_basic_log_debug "$basename has already been sourced, forcing."
                else
                    bu_basic_log_debug "$basename has already been sourced, skipping."
                    return 0
                fi
            fi
            bu_basic_log_debug "sourcing(--__bu-once) $source_filepath"
        fi

        # shellcheck disable=SC2317
        BU_SOURCE_ONCE_CACHE[$basename]=true

        if "$BU_SOURCE_IS_AUTOPUSHD"
        then
            pushd "$dirname" >/dev/null
            source_filepath=$basename
        fi

        if [[ "$BU_SOURCE_IS_INLINE" = true ]]
        then
            if ! "$is_no_inline"
            then
            if [[ -n "$__bu_source_inline_cur_line" ]]
            then
                # echo "${BASH_SOURCE[1]}" "$__bu_source_inline_cur_line,$((BASH_LINENO[0] - 1))"
                sed -n "$__bu_source_inline_cur_line,$(( BASH_LINENO[0] - 1 )) p" "${BASH_SOURCE[1]}" >>"$BU_SOURCE_INLINE_OUTPUT"
                __bu_source_inline_cur_line=$(( BASH_LINENO[0] + 1 ))
            fi
            if declare -f "$source_filepath" >/dev/null
            then
                bu_basic_log_debug "$source_filepath is func"
                sed -n "${BASH_LINENO[0]} p" "${BASH_SOURCE[1]}" >>"$BU_SOURCE_INLINE_OUTPUT"
            else
                local __bu_source_inline_cur_line=1
                builtin source "$source_filepath" "$@"
                # echo "$source_filepath" "$__bu_source_inline_cur_line,$"
                sed -n "$__bu_source_inline_cur_line,$ p" "$source_filepath" >>"$BU_SOURCE_INLINE_OUTPUT"
            fi

            fi
        else
            # Our source implementations allow functions too
            # Functions are in fact more similar to sourcing scripts than invoking a script in a new shell
            # Slight optimization: If source_filepath ends in .sh, then we assume it is a script instead of a function
            case "$source_filepath" in
            *.sh)
                # shellcheck disable=SC2317
                builtin source "$source_filepath" "$@"
                ;;
            *)
                if declare -f "$source_filepath" >/dev/null
                then
                    "$source_filepath" "$@"
                else
                    # shellcheck disable=SC2317
                    builtin source "$source_filepath" "$@"
                fi
                ;;
            esac
        fi

        if "$BU_SOURCE_IS_AUTOPUSHD"
        then
            popd >/dev/null
        fi

        BU_SOURCE_IS_FORCE=$saved_is_force
        BU_SOURCE_IS_AUTOPUSHD=$saved_is_autopushd
        BU_SOURCE_IS_INLINE=$saved_is_inline
        BU_SOURCE_INLINE_OUTPUT=$saved_inline_output
    }
}

# ```
# *Description*:
# Undefine the custom source function and restore the builtin source
# ```
bu_undef_source()
{
    unset -f source
    BU_SOURCE_IS_CUSTOM=false
}

# ```
# *Description*:
# If the custom source function is defined, use it to source the given file(s).
# Otherwise, temporarily define the custom source function, use it to source the given file(s),
# and then undefine the custom source function.
# ```
bu_source()
{
    if "$BU_SOURCE_IS_CUSTOM"
    then
        # shellcheck disable=SC1090
        source "$@"
    else
        bu_def_source
        # shellcheck disable=SC1090
        source "$@"
        bu_undef_source
    fi
}

# ```
# *Description*:
# If the custom source function is defined, undefine it, use the builtin source to source the given file(s),
# and then redefine the custom source function.
# Otherwise, use the builtin source to source the given file(s).
#
# *Bug*:
# Top level `declare` (without `-g`) in a script is broken because we are inside a function
# ```
bu_ext_source()
{
    if "$BU_SOURCE_IS_CUSTOM"
    then
        bu_undef_source
        # shellcheck disable=SC1090
        source "$@"
        bu_def_source
    else
        # shellcheck disable=SC1090
        source "$@"
    fi
}

# ```
# *Description*:
# Source multiple files using the custom source function, ensuring each file is sourced only once.
# ```
bu_source_multi_once()
{
    if ! "$BU_SOURCE_IS_CUSTOM" && (($#))
    then
        bu_basic_log_warn "Using builtin source for bu_source_multi_once, --__bu-once feature will not be effective."
        bu_source_multi "$@"
    else
        local filepath
        for filepath
        do
            # shellcheck disable=SC1090
            source "$filepath" --__bu-once --__bu-no-inline
        done
    fi
}

# ```
# *Description*:
# Source multiple files.
# ```
bu_source_multi()
{
    local filepath
    for filepath
    do
        # shellcheck disable=SC1090
        source "$filepath"
    done
}

bu_def_source
