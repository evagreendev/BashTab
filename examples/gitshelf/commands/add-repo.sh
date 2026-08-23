#!/usr/bin/env bash
# Dispatch: execute
# Help-Topic: gitshelf
# Synopsis: Add a repository to the gitshelf config
function __gitshelf_add_repo_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
# It must exit before any entrypoint sourcing so an incompatible host never
# registers this command.
if [[ "$1" == "--is-compatible" ]]; then
    command -v jq &>/dev/null || { echo "jq is required" >&2; exit 1; }
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

local path=
local tag=
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --path)# PATH
        # Local directory to track (directory completion)
        bu_parse_positional $# "${BU_AUTOCOMPLETE_SPEC_DIRECTORY[@]}" --hint "Local directory path"
        path=${!shift_by}
        ;;
    --tag)# TAG
        # Optional tag to attach
        bu_parse_positional $# --hint "Tag to attach"
        tag=${!shift_by}
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
Add a repository to the gitshelf config (\$GITSHELF_CONFIG_FILE). The repo
name is derived from the basename of --path. The file is rewritten atomically
via jq into a temp file and mv'd into place, so an interrupted write never
leaves a truncated config.
" \
        --example "Add a repo" "--path ~/src/myproject" \
        --example "Add with a tag" "--path ~/src/myproject --tag shell"
    return 0
fi

[[ -n "$path" ]] || {
    error_msg="--path is required"
    bu_autohelp
    bu_scope_pop_function
    return 1
}

[[ -f "$GITSHELF_CONFIG_FILE" ]] || {
    error_msg="config file not found: $GITSHELF_CONFIG_FILE"
    bu_autohelp
    bu_scope_pop_function
    return 1
}

# Normalize the path to an absolute form so records are portable.
local abs_path
if abs_path=$(cd -- "$path" 2>/dev/null && pwd -P)
then
    path=$abs_path
fi

# Repo name = basename of the path.
local name
bu_basename "$path"
name=$BU_RET

# Refuse to overwrite an existing entry.
if jq -e --arg name "$name" '.repos | has($name)' "$GITSHELF_CONFIG_FILE" &>/dev/null
then
    error_msg="Repo[$name] already exists in $GITSHELF_CONFIG_FILE"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

local tmp_file
tmp_file=$(mktemp "${GITSHELF_CONFIG_FILE}.XXXXXX")
if jq --arg name "$name" --arg path "$path" --arg tag "$tag" \
    '.repos[$name] = { path: $path, tags: (if $tag == "" then [] else [$tag] end), comment: "" }' \
    "$GITSHELF_CONFIG_FILE" > "$tmp_file"
then
    mv "$tmp_file" "$GITSHELF_CONFIG_FILE"
    bu_log_info "added repo[$name] path[$path]"
else
    rm -f "$tmp_file"
    error_msg="failed to update $GITSHELF_CONFIG_FILE"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

bu_scope_pop_function
}

__gitshelf_add_repo_main "$@"
