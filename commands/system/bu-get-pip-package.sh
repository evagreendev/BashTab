#!/usr/bin/env bash
function __bu_bu_get_pip_package_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
if [[ "$1" == "--is-compatible" ]]; then
    command -v pip &>/dev/null && command -v jc &>/dev/null && exit 0
    command -v pip3 &>/dev/null && command -v jc &>/dev/null && exit 0
    { echo "pip (or pip3) and jc are required" >&2; exit 1; }
fi

local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local is_help=false
local format=auto
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --format)# FORMAT
        bu_parse_positional $# --enum ${BU_OUT_FORMATS[@]} enum-- --hint "Output format"
        format=${!shift_by}
        ;;
    -h|--help)# _FLAG
        is_help=true
        ;;
    *)
        break
        ;;
    esac
    if "$is_help"; then break; fi
    if (( $# < shift_by )); then bu_parse_error_argn "$1" $#; break; fi
    shift "$shift_by"
done
if bu_env_is_in_autocomplete; then bu_autocomplete; return 0; fi

if "$is_help"; then
    bu_autohelp \
        --description "List installed pip packages as structured records.

Wraps pip list and pipes through jc --pip-list.  Works on any system
with Python and pip installed." \
        --example "Default" ""
    return 0
fi

# Prefer pip3, fall back to pip
local pip_cmd
pip_cmd=$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null)

"$pip_cmd" list --format=columns 2>/dev/null | jc --pip-list 2>/dev/null \
    | jq -c 'if type == "array" then .[] else . end' 2>/dev/null \
    | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_get_pip_package_main "$@"
