#!/usr/bin/env bash
# Dispatch: source
# Synopsis: Run a command or script on remote hosts over ssh
function __bu_bu_invoke_remote_command_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local -a hosts=()
local remote_dir=
local no_host_field=false
local format=jsonl
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
local -a cmd=()
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --host)# HOST
        # Remote host spec ([user@]host); repeatable
        bu_parse_positional $# --hint "Remote host spec ([user@]host)"
        hosts+=("${!shift_by}")
        ;;
    --remote-dir)# REMOTE_DIR
        # Directory to activate the project in on the remote host
        bu_parse_positional $# --hint "Remote directory for project activation"
        remote_dir=${!shift_by}
        ;;
    --no-host-field)# _FLAG
        # Do not inject a host field into JSONL records
        no_host_field=true
        ;;
    --format)# FORMAT
        # Output format (jsonl is passthrough; others go through the output layer)
        bu_parse_positional $# --enum "${BU_OUT_FORMATS[@]}" enum-- --hint "Output format (jsonl is passthrough)"
        format=${!shift_by}
        ;;
    -h|--help)# _FLAG
        # Print help
        is_help=true
        ;;
    --)
        shift
        cmd=("$@")
        set --
        break
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
Run a command (after --) or a script (piped on stdin) on one or more remote
hosts over ssh, reusing a live ControlMaster session when one exists.  JSONL
records produced remotely get a \"host\" field injected (disable with
--no-host-field); non-JSON lines pass through verbatim.  The local machine
(localhost/\$HOSTNAME as \$USER) is short-circuited through a clean
env -i bash -s, so marshal->run->tag->rc works with zero network.

Provide a command after --, or pipe a script on stdin (script mode).  One of
the two is required.
" \
        --example "Run get-module on two hosts" "--host web01 --host web02 -- get-module" \
        --example "Pipe a script block" "echo 'get-module' | bu invoke-command --host web01"
    return 0
fi

if ((${#hosts[@]} == 0))
then
    bu_log_err "At least one --host is required"
    bu_scope_pop_function
    return 1
fi

local -a mode_args=()
if ((${#cmd[@]}))
then
    mode_args=(command "${cmd[@]}")
elif [[ ! -t 0 ]]
then
    local script_block
    script_block=$(cat)
    mode_args=(script "$script_block")
else
    bu_log_err "No command after -- and stdin is a terminal; provide a command or pipe a script"
    bu_scope_pop_function
    return 1
fi

# Marshal the payload to a temp file under the framework tmp dir
local tmp_file
tmp_file=$(mktemp "$BU_TMP_DIR/bu_remote_invoke.XXXXXXXXXX")
bu_scope_add_cleanup rm -f "$tmp_file"

bu_remote_build_script "$remote_dir" "${mode_args[@]}" > "$tmp_file"

local inject=true
"$no_host_field" && inject=false

local rc=0
if [[ "$format" == jsonl || "$format" == auto ]]
then
    bu_remote_invoke "$tmp_file" "$inject" "${hosts[@]}"
    rc=$?
else
    bu_remote_invoke "$tmp_file" "$inject" "${hosts[@]}" | bu_out --format "$format"
    rc=${PIPESTATUS[0]}
fi

bu_scope_pop_function
return "$rc"
}

__bu_bu_invoke_remote_command_main "$@"
