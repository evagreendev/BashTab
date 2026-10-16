#!/usr/bin/env bash
# Pipeline: sink
# Synopsis: Display a file as an fzf-browsable table
function __bu_bu_view_table_main()
{
local -r invocation_dir=$PWD
local script_name script_dir
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

# Source entrypoint (executable script — runs in a new process)
if [[ -z "$COMP_CWORD" ]]; then
    source "$BU_DIR"/bu_entrypoint.sh
fi

bu_exit_handler_setup
bu_scope_push_function
bu_scope_add_cleanup bu_popd_silent
bu_run_log_command "$@"

local columns=
local colors=auto
local is_sidebar=true
local max_width=40
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --columns)# COLUMNS
        # Columns to display, in order (comma-separated). Default: keys of the first record.
        bu_parse_positional $# --hint "Comma-separated columns" --pipeline-fields pipeline-fields--
        columns=${!shift_by}
        ;;
    --colors)# COLORS
        # Colorize column cells: comma-separated key=color pairs, "auto" for
        # rainbow (the default) or "none" for no colors
        bu_parse_positional $# --hint "Comma-separated key=color pairs (e.g. name=green,version=yellow), auto or none"
        colors=${!shift_by}
        ;;
    --max-width)# N
        # Cap column widths at N characters (default 40); w widens the
        # cursor column past the cap, W all columns
        bu_parse_positional $# --hint "Maximum column width (default 40)"
        max_width=${!shift_by}
        ;;
    --no-sidebar)# _FLAG
        # Start with the column sidebar hidden (toggle it with c)
        is_sidebar=false
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
local remaining_options=("$@")
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi

if "$is_help"
then
    bu_autohelp \
        --description "
Interactive table viewer for JSONL streams.  A superior alternative to piping
through less(1) for tabular data — provides fixed headers, a cell cursor,
interactive sort, incremental search and a record-detail view with vim/less
keybindings.

Reads JSONL records from stdin and opens a full-screen TUI.  A sidebar on the
right lists every column and highlights those currently in view; press c to
toggle it.  Press H or F1 for all keys, q to quit.

Keys: j/k/h/l or arrows move the cursor, g/G first/last row, 0/\$/Home/End
first/last column, Space/b/PgDn/PgUp/Shift-Down/Shift-Up page rows,
Shift-Right/Shift-Left (or Ctrl) page columns, Ctrl-D/Ctrl-U half page,
s/S sort the cursor column, w/W widen columns, / and ? search (n/N next and
previous match, Esc clears), Enter shows the record, q quits.
" \
        --example "View all commands" "" \
        --example "Select columns" "--columns name,type,namespace" \
        --example "Without colors" "--colors none" \
        --example "Narrower columns" "--max-width 20" \
        --example "Color only some columns" "--colors name=green,type=yellow"
    return 0
fi

# A leading 0 would reach the viewer's integer variables as (bad) octal
if [[ ! "$max_width" =~ ^[1-9][0-9]*$ ]]
then
    bu_log_err_usage "--max-width must be a positive integer, got [$max_width]"
    bu_scope_pop_function
    return 1
fi

# Source the table viewer engine
# shellcheck source=../../lib/core/bu_core_tv.sh
source "$BU_DIR/lib/core/bu_core_tv.sh"

# Enter the interactive viewer (reads stdin, renders TUI)
bu_tv_enter "$columns" "$colors" "$is_sidebar" "$max_width"
local rc=$?

bu_scope_pop_function
return $rc
}

__bu_bu_view_table_main "$@"
