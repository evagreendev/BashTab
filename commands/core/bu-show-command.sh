#!/usr/bin/env bash
# Pipeline: standalone
# Dispatch: source
# Synopsis: Explore commands in an interactive table and pick one to run
# Help-Topic: commands
function __bu_bu_show_command_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local -a filter_args=()
local is_all=false
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    -v|--verb)# VERB_FILTER
        # Glob pattern to filter by verb
        bu_parse_positional $# --enum "${!BU_COMMAND_VERBS[@]}" enum-- --hint "Command verb glob"
        filter_args+=(--verb "${!shift_by}")
        ;;
    -n|--noun)# NOUN_FILTER
        # Glob pattern to filter by noun
        bu_parse_positional $# --enum "${!BU_COMMAND_NOUNS[@]}" enum-- --hint "Command noun glob"
        filter_args+=(--noun "${!shift_by}")
        ;;
    -ns|--namespace)# NS_FILTER
        # Glob pattern to filter by namespace
        bu_parse_positional $# --enum "${!BU_COMMAND_NAMESPACES[@]}" enum-- --hint "Command namespace glob"
        filter_args+=(--namespace "${!shift_by}")
        ;;
    -t|--type)# TYPE_FILTER
        # Type of the command
        bu_parse_positional $# --enum function execute source alias enum-- --hint "Command type"
        bu_validate_positional "${!shift_by}"
        filter_args+=(--type "${!shift_by}")
        ;;
    -a|--all)# _FLAG
        # Start with the collision-parked (shadowed) commands shown (toggle with a)
        is_all=true
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
    bu_autohelp --description "
Browse every registered command in bu view-table: sort, search (/) and
filter (&) by name, type, pipeline stage or synopsis, and press Enter for
everything bu get-command knows about one (fields, input contract, module,
shadowing). Row actions:

    i   page its --help
    o   open its script, or where its function is defined, in \$VISUAL / \$EDITOR
    u   use it: quit and put 'bu NAME ' on the command line
    a   show / hide collision-parked (shadowed) commands

Bound to a key, u fills the line being edited, e.g. in a module preinit:

    bu_preinit_register_user_defined_key_binding '\\eX' 'bu show-command' 'Explore commands'

Run from the prompt, u adds 'bu NAME' to history instead: press Up to edit it.
" \
        --example "Explore all commands" "" \
        --example "Only get commands" "--verb get" \
        --example "Only the git namespace" "--noun 'git-*'"
    return 0
fi

local reload_cmd
printf -v reload_cmd '%q ' bu get-command --format jsonl "${filter_args[@]}"
reload_cmd+='${BU_SHOW_COMMAND_ALL:+--all}'

# The viewer runs in its own process: u writes the chosen name here
local -r queue=${BU_TMP_DIR:-/tmp}/show-command.$$
: > "$queue"
local -x BU_SHOW_COMMAND_ALL=
"$is_all" && BU_SHOW_COMMAND_ALL=true
eval "$reload_cmd" \
    | BU_SHOW_COMMAND_QUEUE=$queue bu view-table \
        --columns name,type,stage,module,synopsis \
        --max-width 60 \
        --key name \
        --reload "$reload_cmd" \
        --action 'i:help=__bu_cli_show_command_action help' \
        --action 'o:open=__bu_cli_show_command_action open' \
        --action 'u:use=__bu_cli_show_command_action use' \
        --action 'a:all=__bu_cli_show_command_action all'

local name=
name=$(< "$queue")
rm -f "$queue"
if [[ -n "$name" ]]
then
    if [[ -v READLINE_LINE ]]
    then
        # Run from a key binding: fill the line being edited
        READLINE_LINE="${BU_CLI_COMMAND_NAME:-bu} $name "
        READLINE_POINT=${#READLINE_LINE}
    else
        history -s "${BU_CLI_COMMAND_NAME:-bu} $name"
        printf 'Press Up for: %s\n' "${BU_CLI_COMMAND_NAME:-bu} $name"
    fi
fi

bu_scope_pop_function
}

__bu_bu_show_command_main "$@"
