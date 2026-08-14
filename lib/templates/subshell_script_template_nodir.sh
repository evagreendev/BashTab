#!/usr/bin/env bash
# Dispatch: source
function __bu_@BU_SCRIPT_NAME@_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
# Override this block to declare your command's requirements.
# Exit 0 if this command can run on the current system, non-zero otherwise.
# stderr becomes the reason shown in `bu` help.
if [[ "$1" == "--is-compatible" ]]; then
    # Example checks (uncomment and customize):
    # command -v mytool &>/dev/null || { echo "mytool is required" >&2; exit 1; }
    exit 0
fi

# Synopsis: TODO -- one line for the command catalog

# Note that we do not source bu_entrypoint inside the sourceable script template
# as it is assumed that sourceable scripts are sourced AFTER 
# bu_entrypoint has been sourced by the user.

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

# ── Source-isolated command ──────────────────────────────────────────
# This command runs in the caller's shell with READ access only:
#
#   OUTSIDE the ( ... ) subshell (caller's shell):
#       option parsing, bu_autocomplete, bu_autohelp.  Completion must
#       introspect the real shell state and must not fork.
#
#   INSIDE the ( ... ) subshell (child shell):
#       everything else.  Full READ access to the caller's globals and
#       functions; ZERO write access.  `cd`/`export`/PATH edits/
#       `source <env-setup>` die with the subshell.  `return` exits only
#       the subshell; its status becomes this command's exit code.
bu_scope_push_function
bu_run_log_command "$@"

local is_help=false
local error_msg=
local options_finished=false
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    -h|--help)
        # Print help
        is_help=true
        ;;
    --)
        # Remaining options will be collected
        options_finished=true
        shift
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
local remaining_options=("$@")
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi

if "$is_help"
then
    bu_autohelp
    return 0
fi

(
    # ── Subshell body ──
    # Everything from here on runs in a child shell: full READ access to
    # the caller's globals/functions, zero WRITE access.
    bu_exit_handler_setup
    # TODO: implement the command body here
)

bu_scope_pop_function
}

__bu_@BU_SCRIPT_NAME@_main "$@"
