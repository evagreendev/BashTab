#!/usr/bin/env bash
# Pipeline: producer
# Dispatch: source
# Synopsis: Check settings' current values against their registered enum and bool rules
# Help-Topic: config
# Fields: name value origin status detail
function __bu_bu_validate_config_main()
{
# --is-compatible: no external dependencies
if [[ "$1" == "--is-compatible" ]]; then
    exit 0
fi

local -r invocation_dir=$PWD
local script_name script_dir
case "$BASH_SOURCE" in
*/*)
    script_name=${BASH_SOURCE##*/}
    script_dir=${BASH_SOURCE%/*}
    ;;
*)
    script_name=$BASH_SOURCE
    script_dir=.
    ;;
esac
pushd "$script_dir" &>/dev/null

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_scope_add_cleanup bu_popd_silent
bu_run_log_command "$@"

local format=${BU_OUTPUT_FORMAT:-auto}
local -a names=()
local -a allow_args=()
local is_invalid_only=false
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --allow)# VALUE
        # A sentinel value that passes as "not applicable" (repeatable); empty values always do
        bu_parse_positional $# --hint "Sentinel value, e.g. auto or none"
        allow_args+=(--allow "${!shift_by}")
        ;;
    --invalid)# _FLAG
        # Only list the invalid settings
        is_invalid_only=true
        ;;
    --format)# FORMAT
        # Output format
        bu_parse_positional $# --enum ${BU_OUT_FORMATS[@]} enum-- --hint "Output format"
        format=${!shift_by}
        ;;
    -h|--help)# _FLAG
        # Print help
        is_help=true
        ;;
    *)
        # Bare positionals: setting names (default: every setting with an enum or bool rule)
        if bu_env_is_in_autocomplete && (($# == 1)) && [[ "$1" != -* ]]
        then
            autocompletion=(--ret __bu_config_completion_names ret--)
            bu_autocomplete
            return 0
        fi
        if [[ "$1" == -* ]]
        then
            bu_parse_error_enum "$1"
            break
        fi
        names+=("$1")
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
Check the current value of each setting against its registered rule
(bu_config_register --enum, --enum-file or --bool). Nothing validates
settings files at activation: run this, or bu_config_require_valid in a
module's preflight/plan verb, where a bad value matters.

Empty values and --allow sentinels pass as \"not applicable\". The stored
form of a name:mapped entry (BU_LOG_LVL holding 4) passes as well as the
name. An unregistered name is invalid. Exit status 1 when any is invalid.

  bu validate-config
  bu validate-config MYAPP_VENUE MYAPP_NODE --allow auto
  bu validate-config --invalid"
    return 0
fi

local status=0
__bu_config_validate_rows "${allow_args[@]}" "${names[@]}" || status=1
{
    local row rest
    for row in "${__BU_CONFIG_VALIDATE_ROWS[@]}"
    do
        if "$is_invalid_only"
        then
            # status is the 4th field (the value may hold any text)
            rest=${row#*$'\t'*$'\t'*$'\t'}
            [[ "${rest%%$'\t'*}" == invalid ]] || continue
        fi
        printf '%s\n' "$row"
    done
} | bu_out_from_tsv --columns name,value,origin,status,detail | bu_out --format "$format"

bu_scope_pop_function
return "$status"
}

__bu_bu_validate_config_main "$@"
