#!/usr/bin/env bash
# Dispatch: execute
# Help-Topic: gitshelf
# Synopsis: Fetch upstream changes for one or all tracked repositories
# Fields: name path dry_run ok detail
function __gitshelf_sync_repo_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
# It must exit before any entrypoint sourcing so an incompatible host never
# registers this command.
if [[ "$1" == "--is-compatible" ]]; then
    command -v jq &>/dev/null  || { echo "jq is required" >&2; exit 1; }
    command -v git &>/dev/null || { echo "git is required" >&2; exit 1; }
    exit 0
fi

local -r invocation_dir=$PWD
local script_name
local script_dir
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
script_dir=$PWD

if [[ -z "$COMP_CWORD" ]]
then
# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_DIR"/bu_entrypoint.sh
fi

bu_exit_handler_setup
bu_scope_push_function
bu_scope_add_cleanup bu_popd_silent
bu_run_log_command "$@"

local name=
local is_dry_run=false
local format=auto
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --name)# REPO
        # Restrict to one repo (autocompleted from the config file)
        bu_parse_positional $# --stdout jq -r '.repos | keys[]' "$GITSHELF_CONFIG_FILE" stdout-- --hint "Repo name"
        name=${!shift_by}
        ;;
    --dry-run)# _FLAG
        # Report what would be fetched without fetching
        is_dry_run=true
        ;;
    --format)# FORMAT
        # Output format
        bu_parse_positional $# --enum "${BU_OUT_FORMATS[@]}" enum-- --hint "Output format"
        bu_validate_positional "${!shift_by}"
        format=${!shift_by}
        ;;
    -h|--help)# _FLAG
        # Print help
        is_help=true
        ;;
    *)
        bu_parse_error_enum "$1"
        break
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
    bu_autohelp \
        --description "
Run \`git fetch\` for one repo or every tracked repo, emitting one JSONL
record per repo with the fetch outcome. --dry-run reports the command that
would run without touching the network.
" \
        --example "Fetch all repos" "" \
        --example "Fetch one repo" "--name bashtab" \
        --example "Preview without fetching" "--dry-run"
    return 0
fi

[[ -f "$GITSHELF_CONFIG_FILE" ]] || {
    error_msg="config file not found: $GITSHELF_CONFIG_FILE"
    bu_autohelp
    bu_scope_pop_function
    return 1
}

# ── Collect repo names ────────────────────────────────────────────
local -a jq_args=()
local jq_prog='.repos | to_entries[]'
[[ -n "$name" ]] && jq_args+=(--arg name "$name") && jq_prog+=' | select(.key == $name)'
jq_prog+=' | [.key, .value.path] | @tsv'

local -a repo_entries=()
local line
while IFS= read -r line
do
    repo_entries+=("$line")
done < <(jq -r "${jq_args[@]}" "$jq_prog" "$GITSHELF_CONFIG_FILE" 2>/dev/null)

if [[ -n "$name" && ${#repo_entries[@]} -eq 0 ]]
then
    error_msg="Unknown repo[$name]"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

# ── Fetch each repo and emit one record ───────────────────────────
{
    local repo_entry repo_name repo_path resolved_path ok detail output
    for repo_entry in "${repo_entries[@]}"
    do
        IFS=$'\t' read -r repo_name repo_path <<< "$repo_entry"
        if resolved_path=$("$GITSHELF_RESOLVE_PATH_CALLBACK" "$repo_path" 2>/dev/null)
        then
            :
        else
            resolved_path=$repo_path
        fi

        ok=false
        detail=

        if [[ ! -d "$resolved_path" ]]
        then
            detail="missing path"
        elif ! git -C "$resolved_path" rev-parse --git-dir &>/dev/null
        then
            detail="not a git repository"
        elif "$is_dry_run"
        then
            ok=true
            detail="would run: git -C $resolved_path fetch"
        elif output=$(git -C "$resolved_path" fetch 2>&1)
        then
            ok=true
            detail=${output:-"already up to date"}
        else
            detail=$(printf '%s\n' "$output" | head -n 1)
        fi

        bu_out_record \
            name="$repo_name" path="$resolved_path" \
            dry_run:="$is_dry_run" ok:="$ok" detail="$detail"
    done
} | bu_out --format "$format"

bu_scope_pop_function
}

__gitshelf_sync_repo_main "$@"
