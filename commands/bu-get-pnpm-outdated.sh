#!/usr/bin/env bash
function __bu_bu_get_pnpm_outdated_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local project_path=.
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    -h|--help)# _FLAG
        is_help=true
        ;;
    --cwd)# CWD
        bu_parse_positional $# --hint "Project directory path"
        project_path=${!shift_by}
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
List outdated pnpm packages as flat JSONL records (pnpm outdated --json wrapper).
Emits one record per outdated package.

Fields: name, current, wanted, latest, is_deprecated, dependency_type
" \
        --example "Current project" "" \
        --example "Specific directory" "--cwd /path/to/project"
    return 0
fi

if ! command -v pnpm &>/dev/null
then
    error_msg="pnpm is required. Install from https://pnpm.io/installation"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

local pnpm_output
pnpm_output=$(cd "$project_path" && pnpm outdated --json 2>/dev/null) || true

if [[ -z "$pnpm_output" || "$pnpm_output" == "{}" ]]
then
    bu_scope_pop_function
    return 0
fi

# Flatten object keyed by package name into flat records
jq -c 'to_entries[] | {name: .key} + .value' <<<"$pnpm_output" 2>/dev/null | bu_out

bu_scope_pop_function
}

__bu_bu_get_pnpm_outdated_main "$@"
