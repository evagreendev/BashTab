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
# Empty: "auto", or "none" when NO_COLOR is set (resolved by the viewer)
local colors=
local is_sidebar=true
local max_width=40
local -a actions=()
local reload_cmd=
local preview_cmd=
local key_col=
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
        # rainbow (the default) or "none" for no colors.  A non-empty
        # NO_COLOR makes "none" the default.
        bu_parse_positional $# --hint "Comma-separated key=color pairs (e.g. name=green,version=yellow), auto or none"
        colors=${!shift_by}
        ;;
    --max-width)# N
        # Cap column widths at N characters (default 40); w widens the
        # cursor column past the cap, W all columns
        bu_parse_positional $# --hint "Maximum column width (default 40)"
        max_width=${!shift_by}
        ;;
    --action)# KEY[:LABEL]=COMMAND
        # Bind KEY to a row action: COMMAND is eval'd in the viewer's shell
        # with the cursor record (JSON) in BU_TV_RECORD; its last output line
        # shows on the status line. Repeatable. q, Q and H are reserved.
        # Row actions lead the status line, undimmed and set off from the
        # built-in keys by a "·", and head the help (H).
        bu_parse_positional $# --hint "KEY[:LABEL]=COMMAND"
        actions+=("${!shift_by}")
        ;;
    --reload)# COMMAND
        # After each action, replace the rows with COMMAND's JSONL output
        # (run in the viewer's shell), keeping the cursor on its record
        bu_parse_positional $# --hint "Command producing the JSONL rows"
        reload_cmd=${!shift_by}
        ;;
    --preview)# COMMAND
        # Inside tmux, show COMMAND's output for the cursor record in a pane
        # beside the table, following the cursor (p toggles it). COMMAND is
        # eval'd in the background with the record in BU_TV_RECORD and
        # COLUMNS/LINES set to the pane's size. Outside tmux there is no
        # preview.
        bu_parse_positional $# --hint "Command printing the preview"
        preview_cmd=${!shift_by}
        ;;
    --key)# COLUMN
        # Column identifying a record across reloads (default: the row index)
        bu_parse_positional $# --hint "Key column"
        key_col=${!shift_by}
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
s/S sort the cursor column, w/W widen columns, f freezes the cursor column
at the left, - hides it and + brings hidden columns back, </> move it,
/ and ? search (n/N next and previous match), & filters rows, Esc clears
the search then the filter, Enter shows the record, m toggles the mouse,
q quits.  Numeric columns are right-aligned and null shows as ∅.

Mouse: click a cell to move the cursor, double-click a row for its record,
click a header or sidebar entry to select that column, scroll with the
wheel, and click or drag the scrollbar (shown while the rows overflow the
screen).  In the sidebar, the cursor column's ⇤ and × freeze and hide it;
drag an entry to move its column, across the ╌ divider to freeze or
unfreeze it, or onto the Hidden list to hide it, and click a hidden entry
to bring it back.  Click a key hint on the status line to press it.  Press
m to turn mouse reporting off and select text.

Preview: inside tmux, --preview COMMAND opens a pane beside the table showing
COMMAND's output for the cursor record, and keeps it in step as the cursor
moves; p closes and reopens it.  Scroll it with tmux copy mode.  Outside tmux
there is no preview.
" \
        --example "View all commands" "" \
        --example "Select columns" "--columns name,type,namespace" \
        --example "Without colors" "--colors none" \
        --example "Narrower columns" "--max-width 20" \
        --example "Color only some columns" "--colors name=green,type=yellow" \
        --example "Preview each record pretty-printed (inside tmux)" "--preview 'jq -C . <<<\"\$BU_TV_RECORD\"'" \
        --example "Row action with reload (see bu edit-config)" "--key name --reload 'bu get-config --format jsonl' --action 'x:default=bu set-config --unset \"\$(jq -r .name <<<\"\$BU_TV_RECORD\")\"'"
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

# Row actions: KEY[:LABEL]=COMMAND
local spec action_key action_label
for spec in "${actions[@]}"
do
    if [[ "$spec" != ?*=* ]]
    then
        bu_log_err_usage "--action expects KEY[:LABEL]=COMMAND, got [$spec]"
        bu_scope_pop_function
        return 1
    fi
    action_key=${spec%%=*}
    action_label=
    if [[ "$action_key" == *:* ]]
    then
        action_label=${action_key#*:}
        action_key=${action_key%%:*}
    fi
    if ! bu_tv_set_action "$action_key" "$action_label" "${spec#*=}"
    then
        bu_scope_pop_function
        return 1
    fi
done
_TV_RELOAD_CMD=$reload_cmd
_TV_PREVIEW_CMD=$preview_cmd
_TV_KEY_COL=$key_col

# Enter the interactive viewer (reads stdin, renders TUI)
bu_tv_enter "$columns" "$colors" "$is_sidebar" "$max_width"
local rc=$?

bu_scope_pop_function
return $rc
}

__bu_bu_view_table_main "$@"
