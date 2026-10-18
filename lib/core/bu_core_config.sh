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
# The registry, phase state and provenance below are declared guarded, so
# re-sourcing this file (`source ./activate -f`) keeps them: static settings
# stay final. `bu import-environment --reset-source` resets the static phases
# explicitly (__bu_config_static_reset).
declare -p BU_CONFIG_PROPERTIES &>/dev/null || declare -A -g BU_CONFIG_PROPERTIES=()

# Named persistence layers. Each entry maps a layer name to a resolver
# function that prints the layer's settings file path for the current context.
# The "local" layer is built-in (the machine-local settings file).
declare -p BU_CONFIG_LAYER_RESOLVERS &>/dev/null || declare -A -g BU_CONFIG_LAYER_RESOLVERS=()

# Config phases. Every setting belongs to exactly one phase, the one open
# when it was registered. A phase resolves its settings in one step
# (bu_config_phase_end): exported values win, then the phase's own settings
# files, then registered defaults, written to a generated file and sourced.
# The entrypoint runs the built-in "static" and "main" phases; projects can
# add their own. A static phase (--static) is resolved once per shell: its
# values are exported and stay final, so running it again (re-activation) only
# restores any that changed.
#   BU_CONFIG_PHASE_STATE     phase -> open | final
#   __BU_CONFIG_PHASE_STATIC  phase -> true for static phases
#   __BU_CONFIG_PHASE_VARIANT phase -> active variant (e.g. a profile): picks
#                             bu_config_local.PHASE.VARIANT.sh and
#                             --default-for values
#   __BU_CONFIG_PHASE_PREFIX  phase -> required setting-name prefix
#   __BU_CONFIG_OPEN_PHASE    the phase registrations currently go to
#   __BU_CONFIG_RECHECK       true while re-running a final static phase
#   __BU_CONFIG_PHASE_NAMES   settings of the phase being resolved
declare -p BU_CONFIG_PHASE_STATE &>/dev/null || declare -A -g BU_CONFIG_PHASE_STATE=()
declare -p __BU_CONFIG_PHASE_STATIC &>/dev/null || declare -A -g __BU_CONFIG_PHASE_STATIC=()
declare -p __BU_CONFIG_PHASE_VARIANT &>/dev/null || declare -A -g __BU_CONFIG_PHASE_VARIANT=()
declare -p __BU_CONFIG_PHASE_PREFIX &>/dev/null || declare -A -g __BU_CONFIG_PHASE_PREFIX=()
declare -g __BU_CONFIG_OPEN_PHASE=
declare -g __BU_CONFIG_RECHECK=false
declare -a -g __BU_CONFIG_PHASE_NAMES=()

# Settings provenance. Exported values belong to the user: a phase saves them
# before sourcing its settings files and restores them afterwards, so the
# environment beats persisted settings while the files keep plain VAR=value
# assignments (re-sourcing a file by hand still applies it).
#   __BU_CONFIG_USER       name -> value the user exported before the phase ran
#                          (for a static phase, also an unexported value)
#   __BU_CONFIG_USER_KIND  name -> env (exported) or shell (unexported, static)
#   BU_CONFIG_ORIGIN       name -> local | site | callback | layer: who set it
#   BU_CONFIG_SOURCE_FILE  name -> absolute path of the file that set it
#   __BU_CONFIG_APPLIED    name -> value when its phase finished (or after the
#                          last `bu set-config`), to spot later shell edits
#   __BU_CONFIG_SNAP       scratch snapshot for attributing file assignments
declare -p __BU_CONFIG_USER &>/dev/null || declare -A -g __BU_CONFIG_USER=()
declare -p __BU_CONFIG_USER_KIND &>/dev/null || declare -A -g __BU_CONFIG_USER_KIND=()
declare -p BU_CONFIG_ORIGIN &>/dev/null || declare -A -g BU_CONFIG_ORIGIN=()
declare -p BU_CONFIG_SOURCE_FILE &>/dev/null || declare -A -g BU_CONFIG_SOURCE_FILE=()
declare -p __BU_CONFIG_APPLIED &>/dev/null || declare -A -g __BU_CONFIG_APPLIED=()
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
#   - `--env-only`: (static phases) only the environment can set it, never a
#     settings file or `bu set-config`
#   - `--default-for VARIANT VALUE`: (repeatable) the default while the
#     phase's variant is VARIANT, instead of --default
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
    local is_env_only=false
    local -A default_for=()
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
        --env-only)
            is_env_only=true
            shift
            ;;
        --default-for)
            default_for[$2]=$3
            shift 3
            ;;
        *)
            bu_basic_log_err "bu_config_register: unrecognized specifier[$1]"
            return 1
            ;;
        esac
    done
    # Owning phase: the open one; outside any phase, legacy late registration
    # into main (no files, defaults or provenance beyond what the caller does)
    local phase=${__BU_CONFIG_OPEN_PHASE:-main}
    local owner=${BU_CONFIG_PROPERTIES[$name,phase]:-}
    if [[ -z "$__BU_CONFIG_OPEN_PHASE" && -n "${BU_CURRENT_MODULE:-}" && "${BU_CONFIG_PHASE_STATE[main]:-}" == final ]]
    then
        bu_basic_log_warn "bu_config_register: $name registered outside a config phase (module ${BU_CURRENT_MODULE}); register it in ${BU_CURRENT_MODULE}_bu_config.sh so the environment and settings files apply to it"
    fi
    local prefix=${__BU_CONFIG_PHASE_PREFIX[$phase]:-}
    if [[ -n "$prefix" && "$name" != "$prefix"* ]]
    then
        bu_basic_log_err "bu_config_register: settings of config phase '$phase' must start with $prefix (got $name)"
        return 1
    fi
    if [[ -n "$owner" && "$owner" != "$phase" ]]
    then
        bu_basic_log_err "bu_config_register: $name already belongs to config phase '$owner', cannot register it in '$phase'"
        return 1
    fi
    if "$__BU_CONFIG_RECHECK" && [[ "$phase" == "$__BU_CONFIG_OPEN_PHASE" ]]
    then
        # Re-running a final static phase: its settings are already known
        if [[ -z "$owner" ]]
        then
            bu_basic_log_err "bu_config_register: $name registered after static config phase '$phase' was finalized for this shell; it takes effect in a new shell"
        fi
        return 0
    fi
    if "$is_env_only" && [[ "${__BU_CONFIG_PHASE_STATIC[$phase]:-}" != true ]]
    then
        bu_basic_log_err "bu_config_register: --env-only requires a static config phase ($name is in '$phase')"
        return 1
    fi
    BU_CONFIG_PROPERTIES[$name,registered]=true
    BU_CONFIG_PROPERTIES[$name,phase]=$phase
    # The default for the phase's active variant, if one was given
    local variant=${__BU_CONFIG_PHASE_VARIANT[$phase]:-} key
    for key in "${!default_for[@]}"
    do
        BU_CONFIG_PROPERTIES[$name,default_for,$key]=${default_for[$key]}
    done
    if [[ -n "$variant" && -v "default_for[$variant]" ]]
    then
        default=${default_for[$variant]}
    fi
    [[ -n "$default" ]] && BU_CONFIG_PROPERTIES[$name,default]=$default
    [[ -n "$enum" ]] && BU_CONFIG_PROPERTIES[$name,enum]=$enum
    [[ -n "$hint" ]] && BU_CONFIG_PROPERTIES[$name,hint]=$hint
    [[ -n "$presets" ]] && BU_CONFIG_PROPERTIES[$name,presets]=$presets
    "$is_bool" && BU_CONFIG_PROPERTIES[$name,bool]=true
    "$is_env_only" && BU_CONFIG_PROPERTIES[$name,env_only]=true
    [[ -n "$layer" ]] && BU_CONFIG_PROPERTIES[$name,layer]=$layer
    [[ -n "$complete_values_fn" ]] && BU_CONFIG_PROPERTIES[$name,complete_values_fn]=$complete_values_fn
    # Stamp the owning module (mirrors __bu_stamp_command_module and the
    # help-topic stamp in bu_core_help_topic.sh) so `bu get-config` can tell
    # a core BU_* setting from one a module registered. STICKY: only
    # overwrite when BU_CURRENT_MODULE is non-empty, so re-registering a
    # setting outside the entrypoint (where BU_CURRENT_MODULE is empty) never
    # blanks its provenance.
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
# List the names of the settings registered in a config phase.
#
# *Params*:
# - `$1`: Phase name
#
# *Returns*:
# - `BU_RET`: the setting names, sorted
# ```
__bu_config_phase_settings()
{
    local -r phase=$1
    local key
    BU_RET=()
    for key in "${!BU_CONFIG_PROPERTIES[@]}"
    do
        [[ "$key" == *,phase && "${BU_CONFIG_PROPERTIES[$key]}" == "$phase" ]] || continue
        BU_RET+=("${key%,phase}")
    done
    # Insertion sort (a handful of names; no subshell)
    local i j item
    for ((i = 1; i < ${#BU_RET[@]}; i++))
    do
        item=${BU_RET[i]}
        j=$((i - 1))
        while ((j >= 0)) && [[ "${BU_RET[j]}" > "$item" ]]
        do
            BU_RET[j + 1]=${BU_RET[j]}
            j=$((j - 1))
        done
        BU_RET[j + 1]=$item
    done
    return 0
}

# ```
# *Description*:
# Open a config phase: settings registered until bu_config_phase_end belong
# to it. Running a phase again (re-activation) first drops its previous
# registrations, so settings that are no longer registered disappear, and
# resets their values unless exported.
#
# *Params*:
# - `$1`: Phase name (lowercase letters, digits, `_` and `-`)
# - `--static` (optional): resolve once per shell; values are exported and
#   final. Beginning a static phase that is already final re-checks it
#   instead: registrations are ignored and bu_config_phase_end restores any
#   changed value.
# - `--variant VARIANT` (optional): the active variant (e.g. a profile): its
#   settings file bu_config_local.PHASE.VARIANT.sh is sourced after the
#   phase's shared one, and `--default-for VARIANT` defaults apply. Settings
#   registered only for some variants come and go as the phase runs again.
# - `--prefix PREFIX` (optional): every setting of the phase must start with
#   PREFIX, so phases (e.g. profiles) cannot collide by accident
#
# *Returns*: None (always 0; errors are logged)
# ```
bu_config_phase_begin()
{
    local -r phase=$1
    shift
    local is_static=false variant= prefix=
    while (($#))
    do
        case "$1" in
        --static) is_static=true ;;
        --variant) variant=${2:-}; shift ;;
        --prefix) prefix=${2:-}; shift ;;
        *) bu_basic_log_err "bu_config_phase_begin: unrecognized option[$1]" ;;
        esac
        shift
    done
    if [[ -n "$variant" && ! "$variant" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
    then
        bu_basic_log_err "bu_config_phase_begin: invalid variant name[$variant]"
        variant=
    fi
    if [[ ! "$phase" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
    then
        bu_basic_log_err "bu_config_phase_begin: invalid phase name[$phase]"
        return 0
    fi
    if [[ -n "$__BU_CONFIG_OPEN_PHASE" && "$__BU_CONFIG_OPEN_PHASE" != "$phase" ]]
    then
        bu_basic_log_err "bu_config_phase_begin: config phase '$__BU_CONFIG_OPEN_PHASE' is still open; closing it without resolving"
    fi
    __BU_CONFIG_RECHECK=false
    if "$is_static"
    then
        __BU_CONFIG_PHASE_STATIC[$phase]=true
        if [[ "${BU_CONFIG_PHASE_STATE[$phase]:-}" == final ]]
        then
            __BU_CONFIG_RECHECK=true
            __BU_CONFIG_OPEN_PHASE=$phase
            return 0
        fi
    fi

    __bu_config_phase_drop "$phase"
    __BU_CONFIG_PHASE_VARIANT[$phase]=$variant
    __BU_CONFIG_PHASE_PREFIX[$phase]=$prefix
    BU_CONFIG_PHASE_STATE[$phase]=open
    __BU_CONFIG_OPEN_PHASE=$phase
    return 0
}

# ```
# *Description*:
# Drop a config phase's registrations, unsetting their values unless
# exported (the user's).
#
# *Params*:
# - `$1`: Phase name
#
# *Returns*: None (always 0)
# ```
__bu_config_phase_drop()
{
    local -r phase=$1
    local name key attrs
    local -A dropped=()
    __bu_config_phase_settings "$phase"
    for name in "${BU_RET[@]}"
    do
        dropped[$name]=1
        attrs=${!name@a}
        if [[ -v "$name" && "$attrs" != *x* && "$attrs" != *r* ]]
        then
            unset "$name"
        fi
        unset '__BU_CONFIG_USER[$name]' '__BU_CONFIG_USER_KIND[$name]' \
            'BU_CONFIG_ORIGIN[$name]' 'BU_CONFIG_SOURCE_FILE[$name]' '__BU_CONFIG_APPLIED[$name]'
    done
    if ((${#dropped[@]}))
    then
        for key in "${!BU_CONFIG_PROPERTIES[@]}"
        do
            [[ -v "dropped[${key%%,*}]" ]] && unset 'BU_CONFIG_PROPERTIES[$key]'
        done
    fi
    return 0
}

# ```
# *Description*:
# Unload a (non-static) config phase, e.g. to deactivate a profile: drop its
# registrations and unset its values, except exported ones.
#
# *Params*:
# - `$1`: Phase name
#
# *Returns*: None (always 0; errors are logged)
# ```
bu_config_phase_unload()
{
    local -r phase=$1
    if [[ "${__BU_CONFIG_PHASE_STATIC[$phase]:-}" == true ]]
    then
        bu_basic_log_err "bu_config_phase_unload: '$phase' is a static config phase, final for this shell"
        return 0
    fi
    __bu_config_phase_drop "$phase"
    unset 'BU_CONFIG_PHASE_STATE[$phase]' '__BU_CONFIG_PHASE_VARIANT[$phase]' '__BU_CONFIG_PHASE_PREFIX[$phase]'
    [[ "$__BU_CONFIG_OPEN_PHASE" == "$phase" ]] && __BU_CONFIG_OPEN_PHASE=
    return 0
}

# ```
# *Description*:
# List the settings files a config phase sources, in order (later files win).
# For each level, the checkout's file comes first, then the embedder's
# BU_CONFIG_LOCAL_FILE counterpart. The main phase uses bu_config_local.sh
# itself plus site/*.sh; another phase PHASE uses bu_config_local.PHASE.sh,
# then, with an active variant, bu_config_local.PHASE.VARIANT.sh.
#
# *Params*:
# - `$1`: Phase name
#
# *Returns*:
# - `BU_RET`: "ORIGIN:PATH" entries for the files that exist
# ```
__bu_config_phase_files()
{
    local -r phase=$1
    local -r variant=${__BU_CONFIG_PHASE_VARIANT[$phase]:-}
    local -a suffixes=(.sh)
    if [[ "$phase" != main ]]
    then
        suffixes=(".$phase.sh")
        [[ -n "$variant" ]] && suffixes+=(".$phase.$variant.sh")
    fi
    local suffix checkout embedder
    local -a files=()
    for suffix in "${suffixes[@]}"
    do
        checkout=$BU_DIR/config/bu_config_local$suffix
        [[ -f "$checkout" ]] && files+=("local:$checkout")
        if [[ -n "${BU_CONFIG_LOCAL_FILE:-}" ]]
        then
            embedder=${BU_CONFIG_LOCAL_FILE%.sh}$suffix
            [[ "$embedder" == /* ]] || embedder=$PWD/${embedder#./}
            if [[ "$embedder" != "$checkout" && -f "$embedder" ]]
            then
                files+=("local:$embedder")
            fi
        fi
    done
    if [[ "$phase" == main && -d "$BU_DIR/site" ]]
    then
        local site_file
        for site_file in "$BU_DIR"/site/*.sh
        do
            [[ -f "$site_file" ]] && files+=("site:$site_file")
        done
    fi
    BU_RET=("${files[@]}")
    return 0
}

# ```
# *Description*:
# First half of resolving a config phase: save the phase's exported values,
# reset its unexported ones (a static phase keeps them as the user's too), and
# snapshot every registered setting so the
# settings files sourced next can be attributed (__bu_config_phase_track).
# bu_config_phase_end calls the three steps; the entrypoint calls them itself
# to source the main phase's files at top level.
#
# *Params*:
# - `$1`: Phase name (must be the open phase)
#
# *Returns*: None (always 0)
# ```
__bu_config_phase_prepare()
{
    local -r phase=$1
    local name attrs
    __bu_config_phase_settings "$phase"
    __BU_CONFIG_PHASE_NAMES=("${BU_RET[@]}")
    local -r is_static=${__BU_CONFIG_PHASE_STATIC[$phase]:-false}
    for name in "${__BU_CONFIG_PHASE_NAMES[@]}"
    do
        unset '__BU_CONFIG_USER[$name]' '__BU_CONFIG_USER_KIND[$name]' \
            'BU_CONFIG_ORIGIN[$name]' 'BU_CONFIG_SOURCE_FILE[$name]'
        [[ -v "$name" ]] || continue
        attrs=${!name@a}
        if [[ "$attrs" == *x* ]]
        then
            __BU_CONFIG_USER[$name]=${!name}
            __BU_CONFIG_USER_KIND[$name]=env
        elif "$is_static"
        then
            # Static values are exported once final, so a value set before
            # the phase reaches child processes too: it counts as the user's
            __BU_CONFIG_USER[$name]=${!name}
            __BU_CONFIG_USER_KIND[$name]=shell
        elif [[ "$attrs" != *r* ]]
        then
            unset "$name"
        fi
    done
    __bu_config_snapshot
    return 0
}

# Snapshot every registered setting (scratch for __bu_config_phase_track)
__bu_config_snapshot()
{
    local key name
    __BU_CONFIG_SNAP=()
    for key in "${!BU_CONFIG_PROPERTIES[@]}"
    do
        [[ "$key" == *,registered ]] || continue
        name=${key%,registered}
        [[ -v "$name" ]] && __BU_CONFIG_SNAP[$name]=${!name}
    done
    return 0
}

# ```
# *Description*:
# After sourcing one settings file for the phase being resolved: attribute
# the phase's settings it assigned to it, and revert (with a warning) any
# assignment to a setting owned by another phase that has already finished.
#
# *Params*:
# - `$1`: Absolute path of the file just sourced (empty for callbacks)
# - `$2`: Origin to record (`local`, `site` or `callback`)
#
# *Returns*: None (always 0)
# ```
__bu_config_phase_track()
{
    local -r file=$1
    local -r origin=$2
    local -r phase=$__BU_CONFIG_OPEN_PHASE
    local key name owner
    for key in "${!BU_CONFIG_PROPERTIES[@]}"
    do
        [[ "$key" == *,registered ]] || continue
        name=${key%,registered}
        if [[ -v "$name" ]]
        then
            [[ -v "__BU_CONFIG_SNAP[$name]" && "${__BU_CONFIG_SNAP[$name]}" == "${!name}" ]] && continue
        else
            [[ -v "__BU_CONFIG_SNAP[$name]" ]] || continue
        fi
        owner=${BU_CONFIG_PROPERTIES[$name,phase]:-}
        if [[ "$owner" == "$phase" && "${BU_CONFIG_PROPERTIES[$name,env_only]:-}" == true ]]
        then
            bu_basic_log_warn "${file:-$origin}: ignoring assignment to $name, which only the environment can set"
            if [[ -v "__BU_CONFIG_SNAP[$name]" ]]
            then
                printf -v "$name" '%s' "${__BU_CONFIG_SNAP[$name]}" || true
            else
                unset "$name"
            fi
        elif [[ "$owner" == "$phase" || "${BU_CONFIG_PHASE_STATE[$owner]:-}" != final ]]
        then
            # Ours, or a later phase's (that phase resets it when it runs)
            [[ "$owner" == "$phase" && -v "$name" ]] || continue
            BU_CONFIG_ORIGIN[$name]=$origin
            if [[ -n "$file" ]]
            then
                BU_CONFIG_SOURCE_FILE[$name]=$file
            else
                unset 'BU_CONFIG_SOURCE_FILE[$name]'
            fi
            __BU_CONFIG_SNAP[$name]=${!name}
        else
            bu_basic_log_warn "${file:-$origin}: ignoring assignment to $name, a setting of config phase '$owner' (set it in that phase's settings file)"
            if [[ -v "__BU_CONFIG_SNAP[$name]" ]]
            then
                printf -v "$name" '%s' "${__BU_CONFIG_SNAP[$name]}" || true
            else
                unset "$name"
            fi
        fi
    done
    return 0
}

# ```
# *Description*:
# Second half of resolving a config phase: restore the saved exported
# values, then apply registered defaults by generating the phase's vars file
# (one `NAME=${NAME:-default}` line per setting, documented for editors) and
# sourcing it, and record the resulting values.
#
# *Params*:
# - `$1`: Phase name (must be the open phase)
#
# *Returns*: None (always 0)
# ```
__bu_config_phase_complete()
{
    local -r phase=$1
    local name
    for name in "${__BU_CONFIG_PHASE_NAMES[@]}"
    do
        [[ -v "__BU_CONFIG_USER[$name]" ]] || continue
        if [[ "${!name-}" != "${__BU_CONFIG_USER[$name]}" ]]
        then
            printf -v "$name" '%s' "${__BU_CONFIG_USER[$name]}" || true
        fi
        BU_CONFIG_ORIGIN[$name]=${__BU_CONFIG_USER_KIND[$name]}
        unset 'BU_CONFIG_SOURCE_FILE[$name]'
    done

    # Settings registered while the files ran (callbacks) count too
    __bu_config_phase_settings "$phase"
    __BU_CONFIG_PHASE_NAMES=("${BU_RET[@]}")
    __bu_config_write_vars_file "$phase"
    if [[ -n "$BU_RET" ]]
    then
        # shellcheck disable=SC1090
        builtin source "$BU_RET"
    fi
    for name in "${__BU_CONFIG_PHASE_NAMES[@]}"
    do
        __BU_CONFIG_APPLIED[$name]=${!name-}
        if [[ "${__BU_CONFIG_PHASE_STATIC[$phase]:-}" == true ]]
        then
            export "$name"
        fi
    done

    BU_CONFIG_PHASE_STATE[$phase]=final
    __BU_CONFIG_OPEN_PHASE=
    return 0
}

# ```
# *Description*:
# Path of a config phase's generated vars file:
# $BU_OUT_DIR/cache/config-vars/<top-level module>/<BashTab dir>/<phase>[.<variant>].sh
# (the BashTab dir with every character outside [A-Za-z0-9._-] replaced by
# `_`, so checkouts sharing a module name never share a file).
#
# *Params*:
# - `$1`: Phase name
#
# *Returns*:
# - `BU_RET`: the file path
# ```
__bu_config_vars_file()
{
    local -r phase=$1
    local -r variant=${__BU_CONFIG_PHASE_VARIANT[$phase]:-}
    BU_RET=${BU_OUT_DIR:-/tmp/bu/${USER:-unknown}}/cache/config-vars/${BU_TOP_LEVEL_MODULE:-default}/${BU_DIR//[^A-Za-z0-9._-]/_}/$phase${variant:+.$variant}.sh
    return 0
}

# ```
# *Description*:
# Generate the vars file of a config phase from the registry, rewriting it
# only when its content changes (so it stays stable for editors and the
# usual activation needs no extra processes).
#
# *Params*:
# - `$1`: Phase name
#
# *Returns*:
# - `BU_RET`: the file path (__bu_config_vars_file), or empty if it could not
#   be written
# ```
__bu_config_write_vars_file()
{
    local -r phase=$1
    __bu_config_vars_file "$phase"
    local -r file=$BU_RET
    local -r dir=${file%/*}
    local content name default quoted allowed entry
    printf -v content '%s\n' \
        "# Generated by BashTab from the registered settings of config phase '$phase${__BU_CONFIG_PHASE_VARIANT[$phase]:+ (variant ${__BU_CONFIG_PHASE_VARIANT[$phase]})}'." \
        "# Do not edit: rewritten whenever the registered settings change."
    for name in "${__BU_CONFIG_PHASE_NAMES[@]}"
    do
        content+=$'\n'
        [[ -n "${BU_CONFIG_PROPERTIES[$name,hint]:-}" ]] && content+="# ${BU_CONFIG_PROPERTIES[$name,hint]}"$'\n'
        allowed=
        if [[ "${BU_CONFIG_PROPERTIES[$name,bool]:-}" == true ]]
        then
            allowed='true false'
        else
            for entry in ${BU_CONFIG_PROPERTIES[$name,enum]:-}
            do
                allowed+="${allowed:+ }${entry%%:*}"
            done
        fi
        default=${BU_CONFIG_PROPERTIES[$name,default]:-}
        content+="#${allowed:+ allowed: $allowed |} default: ${default:-(empty)} | declared: ${BU_CONFIG_PROPERTIES[$name,defined_at]:-?}"$'\n'
        quoted=
        [[ -n "$default" ]] && printf -v quoted '%q' "$default"
        content+="$name=\${$name:-$quoted}"$'\n'
    done

    BU_RET=
    local existing=
    if [[ -f "$file" ]]
    then
        IFS= read -r -d '' existing < "$file" || true
    fi
    if [[ "$existing" != "$content" ]]
    then
        if [[ ! -d "$dir" ]] && ! mkdir -p "$dir" 2>/dev/null
        then
            bu_basic_log_err "Cannot create $dir; config phase '$phase' defaults not applied"
            return 0
        fi
        if ! { printf '%s' "$content" > "$file.$$" && mv -f "$file.$$" "$file"; } 2>/dev/null
        then
            bu_basic_log_err "Cannot write $file; config phase '$phase' defaults not applied"
            rm -f "$file.$$" 2>/dev/null
            return 0
        fi
    fi
    BU_RET=$file
    return 0
}

# ```
# *Description*:
# Close and resolve a config phase: save exported values, source the phase's
# settings files (__bu_config_phase_files), restore the exported values, then
# apply defaults. Call after the phase's settings are registered.
#
# *Params*:
# - `$1`: Phase name (must be the open phase)
#
# *Returns*: None (always 0; errors are logged)
# ```
bu_config_phase_end()
{
    local -r phase=$1
    if [[ "$__BU_CONFIG_OPEN_PHASE" != "$phase" ]]
    then
        bu_basic_log_err "bu_config_phase_end: config phase '$phase' is not open"
        return 0
    fi
    if "$__BU_CONFIG_RECHECK"
    then
        __bu_config_static_recheck "$phase"
        return 0
    fi
    __bu_config_phase_prepare "$phase"
    local entry
    __bu_config_phase_files "$phase"
    local -a files=("${BU_RET[@]}")
    for entry in "${files[@]}"
    do
        # shellcheck disable=SC1090
        source "${entry#*:}"
        __bu_config_phase_track "${entry#*:}" "${entry%%:*}"
    done
    __bu_config_phase_complete "$phase"
    return 0
}

# ```
# *Description*:
# Re-check a final static phase (re-activation): its values are final for
# the shell, so any that changed since are restored, with a warning.
#
# *Params*:
# - `$1`: Phase name
#
# *Returns*: None (always 0)
# ```
__bu_config_static_recheck()
{
    local -r phase=$1
    local name
    __bu_config_phase_settings "$phase"
    for name in "${BU_RET[@]}"
    do
        [[ -v "__BU_CONFIG_APPLIED[$name]" ]] || continue
        if [[ "${!name-}" != "${__BU_CONFIG_APPLIED[$name]}" ]]
        then
            bu_basic_log_warn "$name is a static setting, final for this shell: keeping '${__BU_CONFIG_APPLIED[$name]}', ignoring '${!name-}' (open a new shell to change it)"
            printf -v "$name" '%s' "${__BU_CONFIG_APPLIED[$name]}" || true
        fi
        export "$name"
    done
    __BU_CONFIG_RECHECK=false
    __BU_CONFIG_OPEN_PHASE=
    return 0
}

# ```
# *Description*:
# Make the static phases resolvable again, for re-initializing a shell
# (`bu import-environment --reset-source`): unset the static values BashTab
# set, keeping the ones the user supplied, and forget that the phases ran.
#
# *Params*: None
#
# *Returns*: None (always 0)
# ```
__bu_config_static_reset()
{
    local phase name
    for phase in "${!__BU_CONFIG_PHASE_STATIC[@]}"
    do
        __bu_config_phase_settings "$phase"
        for name in "${BU_RET[@]}"
        do
            case "${BU_CONFIG_ORIGIN[$name]:-}" in
            env|shell) ;;
            *) unset "$name" ;;
            esac
        done
        unset 'BU_CONFIG_PHASE_STATE[$phase]'
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
