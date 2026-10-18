# bash-ide source=../../bu_custom_source.sh

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

# Settings provenance. Exported values belong to the user: the entrypoint
# saves them before sourcing the settings files and restores them afterwards,
# so the environment beats persisted settings while the files keep plain
# VAR=value assignments (re-sourcing a file by hand still applies it).
#   __BU_CONFIG_USER       name -> value the user supplied before activation
#   __BU_CONFIG_USER_KIND  name -> env (exported) or shell (unexported, only
#                          kept on the first activation in a shell)
#   BU_CONFIG_ORIGIN       name -> local | site | layer: who set the value
#   BU_CONFIG_SOURCE_FILE  name -> absolute path of the file that set it
#   __BU_CONFIG_APPLIED    name -> value at the end of activation (or the last
#                          `bu set-config`), to spot later edits in the shell
#   __BU_CONFIG_SNAP       scratch snapshot for attributing file assignments
declare -A -g __BU_CONFIG_USER=()
declare -A -g __BU_CONFIG_USER_KIND=()
declare -A -g BU_CONFIG_ORIGIN=()
declare -A -g BU_CONFIG_SOURCE_FILE=()
declare -A -g __BU_CONFIG_APPLIED=()
declare -A -g __BU_CONFIG_SNAP=()

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
    # Where the setting is declared (first line of the register call), for
    # the location of a defaulted setting in `bu get-config`.
    local src=${BASH_SOURCE[1]:-}
    if [[ -n "$src" ]]
    then
        [[ "$src" == /* ]] || src=$PWD/${src#./}
        BU_CONFIG_PROPERTIES[$name,defined_at]=$src:${BASH_LINENO[0]}
    fi
    return 0
}

# ```
# *Description*:
# Collect the names of all variables matching BU_CONFIG_NAME_PREFIXES.
# Uses ${!PREFIX@} (via eval on a validated identifier), so no subshells.
#
# *Params*: None
#
# *Returns*:
# - `BU_RET`: the variable names
# ```
__bu_config_prefixed_names()
{
    local prefix
    local -a names=()
    BU_RET=()
    for prefix in "${BU_CONFIG_NAME_PREFIXES[@]}"
    do
        [[ "$prefix" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        eval 'names=(${!'"$prefix"'@})'
        BU_RET+=("${names[@]}")
    done
    return 0
}

# ```
# *Description*:
# Save the setting values the user supplied, before the entrypoint sources
# the settings files. Exported variables are the user's. Unexported values
# of settings registered by an earlier activation in this shell are what
# that activation applied, so they are unset to let the settings files and
# defaults apply again; other unexported values (first activation) are kept
# as the user's too.
#
# *Params*: None
#
# *Returns*: None (always 0)
# ```
__bu_config_save_user_values()
{
    local name attrs
    __BU_CONFIG_USER=()
    __BU_CONFIG_USER_KIND=()
    BU_CONFIG_ORIGIN=()
    BU_CONFIG_SOURCE_FILE=()
    __BU_CONFIG_RESTORE_PENDING=true
    __bu_config_prefixed_names
    for name in "${BU_RET[@]}"
    do
        [[ -v "$name" ]] || continue
        attrs=${!name@a}
        # Settings are scalars
        [[ "$attrs" == *[aAn]* ]] && continue
        if [[ "$attrs" == *x* ]]
        then
            __BU_CONFIG_USER[$name]=${!name}
            __BU_CONFIG_USER_KIND[$name]=env
        elif [[ "${BU_CONFIG_PROPERTIES[$name,registered]:-}" == true ]]
        then
            [[ "$attrs" == *r* ]] || unset "$name"
        else
            __BU_CONFIG_USER[$name]=${!name}
            __BU_CONFIG_USER_KIND[$name]=shell
        fi
    done
    return 0
}

# ```
# *Description*:
# Snapshot the prefixed variables, so __bu_config_track_end can tell which
# ones the next settings file assigned.
#
# *Params*: None
#
# *Returns*: None (always 0)
# ```
__bu_config_track_begin()
{
    local name
    __BU_CONFIG_SNAP=()
    __bu_config_prefixed_names
    for name in "${BU_RET[@]}"
    do
        [[ -v "$name" ]] && __BU_CONFIG_SNAP[$name]=${!name}
    done
    return 0
}

# ```
# *Description*:
# Attribute the variables assigned since the last snapshot to a settings
# file, then update the snapshot for the next file.
#
# *Params*:
# - `$1`: Absolute path of the settings file just sourced
# - `$2`: Origin to record (`local` or `site`)
#
# *Returns*: None (always 0)
# ```
__bu_config_track_end()
{
    local -r file=$1
    local -r origin=$2
    local name
    __bu_config_prefixed_names
    for name in "${BU_RET[@]}"
    do
        [[ -v "$name" ]] || continue
        if [[ ! -v "__BU_CONFIG_SNAP[$name]" || "${__BU_CONFIG_SNAP[$name]}" != "${!name}" ]]
        then
            BU_CONFIG_ORIGIN[$name]=$origin
            BU_CONFIG_SOURCE_FILE[$name]=$file
            __BU_CONFIG_SNAP[$name]=${!name}
        fi
    done
    return 0
}

# ```
# *Description*:
# Put the user's saved values back over whatever the settings files
# assigned. Only registered settings are restored, so a settings file that
# extends a non-setting variable (e.g. BU_MODULE_LIST) is not undone.
# Idempotent: the entrypoint runs it once the core settings are registered
# and again at the end for settings that modules register later.
#
# *Params*: None
#
# *Returns*: None (always 0)
# ```
__bu_config_restore_user_values()
{
    local key name
    for key in "${!BU_CONFIG_PROPERTIES[@]}"
    do
        [[ "$key" == *,registered ]] || continue
        name=${key%,registered}
        [[ -v "__BU_CONFIG_USER[$name]" ]] || continue
        if [[ "${!name-}" != "${__BU_CONFIG_USER[$name]}" ]]
        then
            printf -v "$name" '%s' "${__BU_CONFIG_USER[$name]}" || true
        fi
        BU_CONFIG_ORIGIN[$name]=${__BU_CONFIG_USER_KIND[$name]}
        unset 'BU_CONFIG_SOURCE_FILE[$name]'
    done
    __BU_CONFIG_RESTORE_PENDING=false
    return 0
}

# ```
# *Description*:
# Record the value of every registered setting at the end of activation,
# so `bu get-config` can tell when one was changed in the shell afterwards.
#
# *Params*: None
#
# *Returns*: None (always 0)
# ```
__bu_config_record_applied()
{
    local key name
    __BU_CONFIG_APPLIED=()
    for key in "${!BU_CONFIG_PROPERTIES[@]}"
    do
        [[ "$key" == *,registered ]] || continue
        name=${key%,registered}
        __BU_CONFIG_APPLIED[$name]=${!name-}
    done
    return 0
}

# ```
# *Description*:
# Record a value `bu set-config` just applied in this shell, so provenance
# follows it instead of reporting a change in the shell.
#
# *Params*:
# - `$1`: Setting name
# - `$2`: Origin: `local`, `layer`, or `default` (after --unset)
# - `$3`: Settings file written (ignored for `default`)
#
# *Returns*: None (always 0)
# ```
__bu_config_mark_applied()
{
    local -r name=$1
    local -r origin=$2
    local -r file=${3:-}
    unset '__BU_CONFIG_USER[$name]' '__BU_CONFIG_USER_KIND[$name]'
    if [[ "$origin" == default ]]
    then
        unset 'BU_CONFIG_ORIGIN[$name]' 'BU_CONFIG_SOURCE_FILE[$name]'
    else
        BU_CONFIG_ORIGIN[$name]=$origin
        BU_CONFIG_SOURCE_FILE[$name]=$file
    fi
    __BU_CONFIG_APPLIED[$name]=${!name-}
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
        BU_RET+=("$entry")
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
