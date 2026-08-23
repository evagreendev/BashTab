#!/usr/bin/env bash
# Dispatch: execute
# Help-Topic: gitshelf
# Synopsis: Remove a repository from the gitshelf config
function __gitshelf_remove_repo_main()
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

local name=
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --name)# REPO
        # Repo to remove (autocompleted from the config file)
        bu_parse_positional $# --stdout jq -r '.repos | keys[]' "$GITSHELF_CONFIG_FILE" stdout-- --hint "Repo name"
        name=${!shift_by}
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
Remove a repository from the gitshelf config (\$GITSHELF_CONFIG_FILE). The
file is rewritten atomically via jq into a temp file and mv'd into place.
" \
        --example "Remove a repo" "--name myproject" \
        --example "Remove the framework" "--name bashtab"
    return 0
fi

[[ -n "$name" ]] || {
    error_msg="--name is required"
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

if ! jq -e --arg name "$name" '.repos | has($name)' "$GITSHELF_CONFIG_FILE" &>/dev/null
then
    error_msg="Unknown repo[$name]"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

local tmp_file
tmp_file=$(mktemp "${GITSHELF_CONFIG_FILE}.XXXXXX")
if jq --arg name "$name" 'del(.repos[$name])' "$GITSHELF_CONFIG_FILE" > "$tmp_file"
then
    mv "$tmp_file" "$GITSHELF_CONFIG_FILE"
    bu_log_info "removed repo[$name]"
else
    rm -f "$tmp_file"
    error_msg="failed to update $GITSHELF_CONFIG_FILE"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

bu_scope_pop_function
}

__gitshelf_remove_repo_main "$@"
