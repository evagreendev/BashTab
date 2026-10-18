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
    bu edit-config

${BU_TPUT_BOLD}DESCRIPTION${BU_TPUT_RESET}
    Every BashTab knob is declared once with bu_config_register, which records
    its type, default, allowed values, and help text. bu set-config consumes
    that registry for validation, value mapping, completion, and --unset
    default restore; bu get-config renders it. Modules register their own
    settings the same way, so the whole surface stays discoverable and
    self-documenting.

    Settings live in a small cascade; the first source that defines a value
    wins:

        exported variable  >  settings file  >  registered default

    A value set in the shell without export does not beat the settings file:
    it is reset the next time its config phase runs. Settings files are
    managed by bu set-config inside a "managed block" so hand-written lines
    outside it are never clobbered (and are warned about when they would
    shadow or override the managed value).

${BU_TPUT_BOLD}PHASES${BU_TPUT_RESET}
    Every setting belongs to one config phase, which owns its settings file:

        static    bu_config_local.static.sh   once per shell, then exported
                                               and final until a new shell
        main      bu_config_local.sh, site/   every activation
        NAME      bu_config_local.NAME.sh     phases a project adds
                  (+ .NAME.VARIANT.sh)        (e.g. profiles, as variants)

    bu set-config writes a setting to its phase's file. A file that assigns
    another phase's setting is ignored with a warning. Env-only settings
    (BU_CONFIG_LOCAL_FILE, BU_TOP_LEVEL_MODULE, BU_MODULE_LIST) come only from
    the environment. Modules register settings in NAME_bu_config.sh (main) and
    NAME_bu_config.static.sh (static) next to their preinit.

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

    Browse and change settings interactively (t toggle/step, e edit,
    x default, o open where the value comes from; applied to this shell
    when you quit):
        bu edit-config

    Change a setting (takes effect in the current shell immediately; a
    static setting takes effect in a new shell):
        bu set-config BU_LOG_LVL debug

    Change it for one variant of a phase, or for all of them:
        bu set-config --variant prod MYAPP_URL https://prod.example
        bu set-config --all-variants MYAPP_REGION eu

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

    "...: ignoring assignment to BU_X, a setting of config phase 'static'"
        The settings file belongs to another phase. Set it in that phase's
        file (bu set-config does this for you).

    "BU_X is a static setting, final for this shell: keeping ..."
        A static value changed after the shell activated. Open a new shell
        (or bu import-environment --reset-source) to apply it.

    "BU_X can only be set in the environment ..."
        An env-only setting: export it before activating.

    "note: BU_X is also assigned AFTER the managed block ..."
        A hand-written assignment outside the managed block overrides (after)
        or is shadowed by (before) the value just set. File order wins.

${BU_TPUT_BOLD}SEE ALSO${BU_TPUT_RESET}
    bu get-command          list commands and their output fields
    bu get-module           list loaded modules
    config/bu_config_static.sh    the built-in static settings
    config/bu_config_dynamic.sh   the built-in main-phase settings
EOF
