#!/usr/bin/env bash
function __bu_bu_get_npm_outdated_main()
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
        # Print help
        is_help=true
        ;;
    --cwd)# CWD
        # Project directory (default: current directory)
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
List outdated npm packages as flat JSONL records (npm outdated --json wrapper).
Emits one record per outdated package.

Fields: name, current, wanted, latest, dependent, location
" \
        --example "Current project" "" \
        --example "Filter devDependencies" "| bu where-object '.location | test(\"node_modules\")'"
    return 0
fi

if ! command -v npm &>/dev/null
then
    error_msg="npm is required. Install Node.js from https://nodejs.org"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

# Run npm outdated --all --json from the project directory, flatten to JSONL
local npm_output
npm_output=$(cd "$project_path" && npm outdated --all --json 2>/dev/null) || true

if [[ -z "$npm_output" || "$npm_output" == "{}" ]]
then
    # Nothing outdated — produce no output (PowerShell semantics)
    bu_scope_pop_function
    return 0
fi

# Flatten object keyed by package name into flat records.
# { "chalk": { "current": "5.3.0", ... } } → { "name": "chalk", "current": "5.3.0", ... }
jq -c 'to_entries[] | {name: .key} + .value' <<<"$npm_output" 2>/dev/null | bu_out

bu_scope_pop_function
}

__bu_bu_get_npm_outdated_main "$@"
