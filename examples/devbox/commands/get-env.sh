#!/usr/bin/env bash
# Dispatch: execute
# Help-Topic: devbox
# Synopsis: One JSONL record of environment facts
# Fields: shell user home cwd host bash_version
function __devbox_get_env_main()
{
# --is-compatible: this command only needs a POSIX-ish shell and coreutils,
# so it always passes. Keep the probe anyway for uniformity with the other
# commands (and so it exits before any entrypoint sourcing).
if [[ "$1" == "--is-compatible" ]]; then
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

local format=auto
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
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
Emit a single JSONL record of environment facts. Proves the host project has
its own commands alongside the gitshelf library's, all under one registry.
" \
        --example "One record" "" \
        --example "As JSON" "--format json"
    return 0
fi

bu_out_record \
    shell="${SHELL:-}" \
    user="${USER:-}" \
    home="${HOME:-}" \
    cwd="$invocation_dir" \
    host="${HOSTNAME:-}" \
    bash_version="${BASH_VERSION:-}" \
    | bu_out --format "$format"

bu_scope_pop_function
}

__devbox_get_env_main "$@"
