# Synopsis: BashTab's declarative configuration system

# Live checks. This file is sourced in a subshell by `bu get-help`, so plain
# assignments here cannot leak into the invoking shell. Dynamic values are
# computed up front, then interpolated into the heredoc below.

_local_file=${BU_CONFIG_LOCAL_FILE:-"$BU_DIR"/config/bu_config_local.sh}
_prefixes=${BU_CONFIG_NAME_PREFIXES[*]}

_settings_count=0
_layers="local"
for _k in "${!BU_CONFIG_LAYER_RESOLVERS[@]}"; do
    [[ -n "${BU_CONFIG_LAYER_RESOLVERS[$_k]}" ]] && _layers+=" $_k"
done
for _key in "${!BU_CONFIG_PROPERTIES[@]}"; do
    [[ "$_key" == *,registered ]] && ((_settings_count++))
done

# Live table of registered settings: name, current value, default. Derived
# from BU_CONFIG_PROPERTIES (the same registry that drives bu get-config).
_settings_table=$(for _key in "${!BU_CONFIG_PROPERTIES[@]}"; do
    [[ "$_key" == *,registered ]] || continue
    _name=${_key%,registered}
    _cur=${!_name:-}
    _def=${BU_CONFIG_PROPERTIES[$_name,default]:-}
    printf '    %-34s %-14s %s\n' "$_name" "${_cur:-(unset)}" "${_def:+default: $_def}"
done | sort)

_cmd_table=$(bu_help_topic_commands_tagged config "$BU_BUILTIN_COMMANDS_DIR/core")

cat <<EOF
${BU_TPUT_BOLD}NAME${BU_TPUT_RESET}
    config — BashTab's declarative configuration system

${BU_TPUT_BOLD}SYNOPSIS${BU_TPUT_RESET}
    bu set-config BU_LOG_LVL debug
    bu set-config --unset BU_LOG_LVL
    bu get-config

${BU_TPUT_BOLD}DESCRIPTION${BU_TPUT_RESET}
    Every BashTab knob is declared once with bu_config_register, which records
    its type, default, allowed values, and help text. bu set-config consumes
    that registry for validation, value mapping, completion, and --unset
    default restore; bu get-config renders it. Modules register their own
    settings the same way, so the whole surface stays discoverable and
    self-documenting.

    Settings live in a small cascade; the first source that defines a value
    wins:

        environment  >  machine-local file  >  registered default

    The machine-local file is managed by bu set-config inside a "managed
    block" so hand-written lines outside it are never clobbered (and are
    warned about when they would shadow or override the managed value).

${BU_TPUT_BOLD}LAYERS${BU_TPUT_RESET}
    A "layer" is a named settings file resolved for the current context. The
    built-in layer is:

        local     $_local_file

    Modules can add layers (e.g. per-project, per-repo) with
    bu_config_register_layer NAME resolver_fn, then route writes there with
    bu set-config --layer NAME. A registered setting may declare a natural
    layer; writing it elsewhere warns that the cascade may shadow the value.

${BU_TPUT_BOLD}THIS MACHINE${BU_TPUT_RESET}
    local settings file:  $_local_file
    name prefixes:        $_prefixes
    registered settings:  $_settings_count
    layers:               $_layers

    Current values (run bu get-config for allowed values and descriptions):

$_settings_table

${BU_TPUT_BOLD}COMMANDS${BU_TPUT_RESET}
    Derived from commands/core/ — only files tagged # Help-Topic: config:

$_cmd_table

${BU_TPUT_BOLD}TYPICAL FLOWS${BU_TPUT_RESET}
    Read the whole surface:
        bu get-config

    Change a setting (takes effect in the current shell immediately):
        bu set-config BU_LOG_LVL debug

    Revert to the registered default:
        bu set-config --unset BU_LOG_LVL

    Preview without writing:
        bu set-config --dry-run BU_TABLE_PAGER preset:bat

    Write to a specific layer:
        bu set-config --layer proj BU_LOG_LVL info

${BU_TPUT_BOLD}FAILURE SIGNATURES${BU_TPUT_RESET}
    "Setting name must match ^(BU_)[A-Z0-9_]+\$ ..."
        The name is not a valid BashTab setting. Names are uppercase with an
        allowed prefix (BU_CONFIG_NAME_PREFIXES). Modules must append their
        own prefix (e.g. BU_CONFIG_NAME_PREFIXES+=(MYAPP_)).

    "Invalid value for BU_LOG_LVL: expected one of: ..."
        The value is not in the setting's registered enum (or not true/false
        for a --bool). bu get-config lists each setting's allowed values.

    "Unknown config layer 'x'. Registered layers: local, ..."
        The --layer name has no registered resolver. Use bu_config_register_layer
        first, or drop --layer to use the machine-local file.

    "Managed block markers ... are inconsistent"
        The settings file's managed block was hand-edited. Restore exactly one
        opener+closer pair (or delete both markers) and retry.

    "note: BU_X is also assigned AFTER the managed block ..."
        A hand-written assignment outside the managed block overrides (after)
        or is shadowed by (before) the value just set. File order wins.

${BU_TPUT_BOLD}SEE ALSO${BU_TPUT_RESET}
    bu get-command          list commands and their output fields
    bu get-module           list loaded modules
    config/bu_config_dynamic.sh   the built-in settings and their declarations
EOF
