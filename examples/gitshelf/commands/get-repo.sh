#!/usr/bin/env bash
# Dispatch: execute
# Help-Topic: gitshelf
# Synopsis: Survey configured git repositories (config joined with live state)
# Fields: name path tags comment branch dirty ahead behind missing
function __gitshelf_get_repo_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
# It must exit before any entrypoint sourcing so an incompatible host never
# registers this command. Exit 0 if it can run, non-zero with a reason on
# stderr otherwise.
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
local tag=
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
    --tag)# TAG
        # Restrict to repos carrying this tag (autocompleted from the config file)
        bu_parse_positional $# --stdout jq -r '[.repos[].tags[]?] | unique[]' "$GITSHELF_CONFIG_FILE" stdout-- --hint "Tag"
        tag=${!shift_by}
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
Survey the repositories tracked in \$GITSHELF_CONFIG_FILE, joining static
config (name, path, tags, comment) with live state probed from each working
tree (current branch, dirty/clean, ahead/behind upstream). A repo whose path
does not exist is still listed, with missing=true and empty live fields.

This is the flagship JSONL survey: it mirrors the \"config joined with live
system state\" shape that makes a JSONL pipeline useful. Pipe it into
query-object / where / select to slice the shelf.
" \
        --example "All repos (auto table on a terminal)" "" \
        --example "JSONL for piping" "--format jsonl" \
        --example "One repo" "--name bashtab" \
        --example "Repos with a tag" "--tag shell"
    return 0
fi

# ── Collect matching repo names from the config ───────────────────
[[ -f "$GITSHELF_CONFIG_FILE" ]] || {
    error_msg="config file not found: $GITSHELF_CONFIG_FILE"
    bu_autohelp
    bu_scope_pop_function
    return 1
}

local -a jq_args=()
local jq_prog='.repos | to_entries[]'
[[ -n "$name" ]] && jq_args+=(--arg name "$name") && jq_prog+=' | select(.key == $name)'
[[ -n "$tag" ]] && jq_args+=(--arg tag "$tag") && jq_prog+=' | select((.value.tags // []) | index($tag) != null)'
jq_prog+=' | [.key, .value.path, ((.value.tags // []) | join(",")), (.value.comment // "")] | @tsv'

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

# ── Emit one JSONL record per repo ────────────────────────────────
{
    local repo_entry repo_name repo_path repo_tags repo_comment
    local resolved_path is_repo branch dirty ahead behind missing counts
    for repo_entry in "${repo_entries[@]}"
    do
        IFS=$'\t' read -r repo_name repo_path repo_tags repo_comment <<< "$repo_entry"

        # Resolve the configured path through the (overridable) callback.
        if resolved_path=$("$GITSHELF_RESOLVE_PATH_CALLBACK" "$repo_path" 2>/dev/null)
        then
            :
        else
            resolved_path=$repo_path
        fi

        is_repo=false
        branch=
        dirty=false
        ahead=
        behind=
        missing=true

        if [[ -d "$resolved_path" ]]
        then
            missing=false
            if git -C "$resolved_path" rev-parse --git-dir &>/dev/null
            then
                is_repo=true
                branch=$(git -C "$resolved_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
                if [[ -n "$(git -C "$resolved_path" status --porcelain --untracked-files=no 2>/dev/null)" ]]
                then
                    dirty=true
                fi
                if counts=$(git -C "$resolved_path" rev-list --left-right --count '@{upstream}...@' 2>/dev/null)
                then
                    ahead=${counts%%$'\t'*}
                    behind=${counts#*$'\t'}
                fi
            fi
        fi

        bu_out_record \
            name="$repo_name" path="$resolved_path" tags="$repo_tags" comment="$repo_comment" \
            branch="$branch" dirty:="$dirty" \
            ahead:="${ahead:-null}" behind:="${behind:-null}" missing:="$missing"
    done
} | bu_out --format "$format"

bu_scope_pop_function
}

__gitshelf_get_repo_main "$@"
