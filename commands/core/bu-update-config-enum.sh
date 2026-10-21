#!/usr/bin/env bash
# Pipeline: producer
# Dispatch: source
# Synopsis: Refresh file-backed setting enums from their --enum-source
# Help-Topic: config
# Fields: name file kind value action
function __bu_bu_update_config_enum_main()
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
local -a refresh_args=()
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --execute)# _FLAG
        # Rewrite the files (default: only show what would change)
        refresh_args=(--execute)
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
        # Bare positionals: setting names (default: every setting registered with --enum-source)
        if bu_env_is_in_autocomplete && (($# == 1)) && [[ "$1" != -* ]]
        then
            autocompletion=(--ret __bu_config_completion_enum_source_names ret--)
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
Refresh the --enum-file of settings registered with an --enum-source: run
the source, compare its values with the file's generated section, and list
each added and removed value plus a summary per setting. --execute rewrites
the files (header and hand-kept section kept, generated section replaced
under a dated marker) and updates the allowed values in this shell.

  bu update-config-enum
  bu update-config-enum MYAPP_VENUE --execute"
    return 0
fi

if ((${#names[@]} == 0))
then
    __bu_config_completion_enum_source_names
    names=("${BU_RET[@]}")
    __bu_config_sort_names names
fi

# Refresh in this shell (not in the pipeline below) so --execute updates the
# live enums; print the collected rows afterwards.
local status=0 name
__BU_CONFIG_REFRESH_ROWS=()
for name in "${names[@]}"
do
    __bu_config_refresh_enum_rows "$name" "${refresh_args[@]}" || status=1
done
{
    ((${#__BU_CONFIG_REFRESH_ROWS[@]})) && printf '%s\n' "${__BU_CONFIG_REFRESH_ROWS[@]}"
} | bu_out_from_tsv --columns name,file,kind,value,action | bu_out --format "$format"

bu_scope_pop_function
return "$status"
}

__bu_bu_update_config_enum_main "$@"
