#!/usr/bin/env bash
function __bu_bu_get_docker_container_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local is_all=false
local is_help=false
local format=auto
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --format)# FORMAT
        # Output format
        bu_parse_positional $# --enum $BU_OUT_FORMATS enum-- --hint "Output format"
        format=${!shift_by}
        ;;
    -h|--help)# _FLAG
        is_help=true
        ;;
    -a|--all)# _FLAG
        # Show all containers (including stopped)
        is_all=true
        ;;
    *)
        bu_parse_error_enum "$1"
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
local remaining_options=("$@")
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi

if "$is_help"
then
    bu_autohelp \
        --description "
List Docker containers as JSONL records (docker ps --format json wrapper).

Fields: ID, Image, Command, CreatedAt, RunningFor, Ports, Status, Size, Names, Labels, Mounts, Networks
" \
        --example "Running containers" "" \
        --example "All containers" "-a" \
        --example "Filter by image" "| bu where-object '.Image | startswith(\"nginx\")'" \
        --example "Show names and ports" "| bu select-object Names,Ports,Status"
    return 0
fi

if ! command -v docker &>/dev/null
then
    error_msg="docker is required. Install from https://docs.docker.com/engine/install/"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

local -a docker_args=(ps --format json)
"$is_all" && docker_args+=(-a)
docker "${docker_args[@]}" 2>/dev/null | bu_format_jsonl | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_get_docker_container_main "$@"
