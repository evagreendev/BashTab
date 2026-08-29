#!/usr/bin/env bash
# Dispatch: source
# Synopsis: Close (or clean up) a remote ControlMaster session
function __bu_bu_remove_remote_session_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local -a specs=()
local all=false
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --all)# _FLAG
        # Remove every session in the socket directory
        all=true
        ;;
    -h|--help)# _FLAG
        # Print help
        is_help=true
        ;;
    -*)
        bu_parse_error_enum "$1"
        break
        ;;
    *)
        specs+=("$1")
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
Close a remote ControlMaster session (ssh -O exit), or clean up a stale
socket when the master is already gone.  WARNING: a live master may be the
only remaining route to a host if the credentials that opened it are gone —
closing it can strand you.
"
    return 0
fi

local rc=0
if "$all"
then
    local dir
    __bu_remote_ssh_dir
    dir=$BU_RET
    local sock spec
    for sock in "$dir"/cm-*
    do
        [[ -e "$sock" ]] || continue
        bu_basename "$sock"
        spec=${BU_RET#cm-}
        __bu_remote_remove_spec "$spec" || rc=1
    done
else
    if ((${#specs[@]} == 0))
    then
        bu_log_err "Provide at least one spec or --all"
        bu_scope_pop_function
        return 1
    fi
    local spec
    for spec in "${specs[@]}"
    do
        __bu_remote_remove_spec "$spec" || rc=1
    done
fi

bu_scope_pop_function
return "$rc"
}

__bu_bu_remove_remote_session_main "$@"
