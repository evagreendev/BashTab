#!/usr/bin/env bash
# Pipeline: standalone
# Dispatch: source
# Synopsis: Edit BashTab configuration settings in an interactive table
# Help-Topic: config
function __bu_bu_edit_config_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

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
    bu_autohelp --description "
Browse the settings in bu view-table and change them in place:

    t   toggle a true/false setting, or step to its next allowed value
    e   type a new value
    x   restore the registered default
    o   open where its value comes from in \$VISUAL / \$EDITOR: the settings
        file line that set it, or where a defaulted setting is registered

Each change goes through bu set-config, so it is validated, stored in the
setting's config-phase settings file at once, and the table reloads. The
viewer runs in its own process: when it exits, the changes are applied to
this shell too. Static settings take effect in a new shell.
" \
        --example "Edit settings" ""
    bu_scope_pop_function
    return 0
fi

# Actions run inside the viewer (its own process) and queue each change for
# this shell; the queue is replayed once the viewer exits
local -r queue=${BU_TMP_DIR:-/tmp}/edit-config.$$.sh
: > "$queue"
bu get-config --format jsonl \
    | BU_CONFIG_EDIT_QUEUE=$queue bu view-table \
        --columns name,value,origin,phase,default,allowed,description \
        --key name \
        --reload 'bu get-config --format jsonl' \
        --action 't:toggle=__bu_config_edit_action cycle' \
        --action 'e:edit=__bu_config_edit_action prompt' \
        --action 'x:default=__bu_config_edit_action unset' \
        --action 'o:open=__bu_config_edit_action open'

local -a changes=()
mapfile -t changes < "$queue"
if ((${#changes[@]}))
then
    # shellcheck disable=SC1090
    builtin source "$queue"
    printf 'Applied %s change(s) to this shell\n' "${#changes[@]}"
fi
rm -f "$queue"

bu_scope_pop_function
}

__bu_bu_edit_config_main "$@"
