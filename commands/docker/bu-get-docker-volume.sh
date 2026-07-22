#!/usr/bin/env bash
function __bu_bu_get_docker_volume_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
# Exit 0 if this command can run on the current system, non-zero otherwise.
# stderr becomes the reason shown in `bu` help.
if [[ "$1" == "--is-compatible" ]]; then
    command -v docker &>/dev/null || { echo "docker is required" >&2; exit 1; }
    exit 0
fi
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local is_help=false
local format=auto
local error_msg=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --format)# FORMAT
        # Output format
        bu_parse_positional $# --enum ${BU_OUT_FORMATS[@]} enum-- --hint "Output format"
        format=${!shift_by}
        ;;
    -h|--help)# _FLAG
        is_help=true
        ;;
    *)
        bu_parse_error_enum "$1"
        ;;
    esac
    if "$is_help"
    then
        break
    fi
    shift
done
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi

if "$is_help"
then
    bu_autohelp \
        --description "
List Docker volumes as JSONL records (docker volume ls --format json wrapper).

Fields: Driver, Labels, Links, Mountpoint, Name, Scope, Size
" \
        --example "All volumes" ""
    return 0
fi

if ! command -v docker &>/dev/null
then
    error_msg="docker is required."
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

docker volume ls --format json 2>/dev/null | bu_format_jsonl | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_get_docker_volume_main "$@"
