#!/usr/bin/env bash
function __bu_bu_set_config_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

# Machine-local settings file. Overridable for tests.
local file=${BU_CONFIG_LOCAL_FILE:-"$BU_DIR"/config/bu_config_local.sh}

local var=
local value=
local is_unset=false
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    -u|--unset)# _FLAG
        # Remove VAR's assignments from the settings file (registered default restored)
        is_unset=true
        ;;
    -h|--help)# _FLAG
        # Print help
        is_help=true
        ;;
    *)
        # Bare positionals: VAR then VALUE
        if bu_env_is_in_autocomplete && (($# == 1))
        then
            # $1 is the word being completed
            if [[ "$1" == -* ]]
            then
                : # keep bu_parse_multiselect's --options-at completion
            elif [[ -z "$var" ]]
            then
                autocompletion=(--ret __bu_config_completion_names ret--)
            elif [[ -z "$value" ]]
            then
                autocompletion=(--ret __bu_config_completion_values "$var" ret--)
            fi
            bu_autocomplete
            return 0
        fi
        if [[ -z "$var" ]]
        then
            var=$1
        elif [[ -z "$value" ]]
        then
            value=$1
        else
            bu_parse_error_enum "$1"
            break
        fi
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
    bu_autohelp
    return 0
fi

# ── Helpers ─────────────────────────────────────────────────
__bu_set_config_ensure_file()
{
    if [[ ! -f "$file" ]]
    then
        cat > "$file" <<'EOF'
# BashTab local settings (machine-local, not committed).
# Managed by `bu set-config`; manual edits are fine — later assignments win.
EOF
    fi
}

# Remove existing assignment lines for $1 from the settings file (dedupe:
# appending later would win anyway, this just keeps the file short).
__bu_set_config_strip_var()
{
    local name=$1
    local kept
    kept=$(grep -v -E "^(export )?${name}=" "$file" 2>/dev/null || true)
    if [[ -n "$kept" ]]
    then
        printf '%s\n' "$kept" > "$file"
    else
        : > "$file"
    fi
}

# ── Validate VAR ────────────────────────────────────────────
if [[ ! "$var" =~ ^BU_[A-Z0-9_]+$ ]]
then
    bu_log_err "Setting name must match BU_[A-Z0-9_]+ (got: '${var:-<empty>}')"
    bu_log_err "Usage: bu set-config BU_SOME_SETTING value | --unset BU_SOME_SETTING"
    bu_scope_pop_function
    return 1
fi

if "$is_unset"
then
    __bu_set_config_ensure_file
    __bu_set_config_strip_var "$var"
    if [[ -n "${BU_CONFIG_PROPERTIES[$var,default]:-}" ]]
    then
        # Registered default restored immediately
        declare -g "$var=${BU_CONFIG_PROPERTIES[$var,default]}"
    else
        unset "$var"
        # Re-apply repo defaults for anything the dynamic config owns
        source "$BU_DIR"/config/bu_config_dynamic.sh
    fi
    printf 'Unset %s in %s (default applies)\n' "$var" "$file"
    bu_scope_pop_function
    return 0
fi

if [[ -z "$value" ]]
then
    bu_log_err "Missing value. Usage: bu set-config $var VALUE (see also: bu get-config)"
    bu_scope_pop_function
    return 1
fi

# ── Registry-driven validation + value mapping ──────────────
if [[ "${BU_CONFIG_PROPERTIES[$var,registered]:-}" == true ]]
then
    if bu_config_validate_value "$var" "$value"
    then
        value=$BU_RET
    else
        bu_log_err "Invalid value for $var: $BU_RET"
        bu_scope_pop_function
        return 1
    fi
else
    bu_log_warn "$var is not a registered setting; storing anyway (register it with bu_config_register)"
fi

__bu_set_config_ensure_file
__bu_set_config_strip_var "$var"
printf '%s=%q\n' "$var" "$value" >> "$file"

# Take effect immediately in the current shell (this command is sourced).
declare -g "$var=$value"

printf 'Set %s=%s in %s\n' "$var" "$value" "$file"
bu_scope_pop_function
}

__bu_bu_set_config_main "$@"
