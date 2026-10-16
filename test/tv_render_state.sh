#!/usr/bin/env bash
# test/tv_render_state.sh <state>
#
# Renders one frame of bu view-table for a canned viewer state and writes it
# to stdout.  Used to capture golden fixture frames (test/fixtures/) and by
# test/tv_test.bats to compare the live renderer against those fixtures.
#
# Run in a child bash (not sourced into bats) so the bats DEBUG trap does
# not inflate pure-bash loops.
#
# States:
#   plain            - 5 records, no search, no colors, cursor at (0, 0)
#   scrolled         - 4 data rows, cursor on the last row and column
#   cursor           - cursor at row 3, column 2 (reverse row, underlined header)
#   search           - query "get": hits inside and outside the cursor row
#   search_truncated - query "table" with --max-width 10: hits behind the ellipsis
#   search_expanded  - search_truncated with the name column widened (w)
#   regex            - query "m?n" (glob/regex metachars must match literally)
#   prompt           - the search prompt open with "ge" typed
#   detail           - record-detail overlay: wrapping, nested JSON, newlines
#   help             - help overlay
#   nosidebar        - plain, with the column sidebar hidden
#   sorted           - sorted by verb descending, cursor on namespace
#   overflow         - 14 columns in a 12-row terminal: the sidebar list scrolls
#   paged            - overflow data after one page right (Shift-→) from column 0
#   scrollbar        - 40 rows for 17 data rows: cursor on row 26, thumb 7 rows
#   filter           - rows filtered to "source" (3 of 5)
#   numeric          - numeric columns right-aligned, nulls as ∅, cursor row 2
#   frozen           - overflow data, col01 frozen, one page right
#   markers          - frozen, sidebar hidden: "◂ N" / "N ▸" on the separator row
#   hidden           - the verb column hidden

set -u

# Pin the locale: under a non-UTF-8 locale bash measures bytes, so the
# frame (sidebar │, truncation) would depend on the caller
export LC_ALL=C.UTF-8

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=../bu_entrypoint.sh
source "$DIR"/../bu_entrypoint.sh >/dev/null 2>&1
# shellcheck source=../lib/core/bu_core_tv.sh
source "$DIR"/../lib/core/bu_core_tv.sh

state=${1:-plain}

_TV_ROWS=(
    '{"name":"get-command","verb":"get","noun":"command","namespace":"bu","type":"source"}'
    '{"name":"format-table","verb":"format","noun":"table","namespace":"bu","type":"source"}'
    '{"name":"convert-from-asciitable","verb":"convert-from","noun":"asciitable","namespace":"bu","type":"execute"}'
    '{"name":"query-object","verb":"query","noun":"object","namespace":"bu","type":"source"}'
    '{"name":"select-string","verb":"select","noun":"string","namespace":"bu","type":"alias"}'
)
_TV_TERM_ROWS=20
_TV_TERM_COLS=60

case $state in
overflow|paged|frozen|markers)
    _TV_ROWS=()
    for i in 1 2 3
    do
        row= sep=
        for c in {01..14}
        do
            row+="$sep\"col$c\":\"value-$i\""
            sep=,
        done
        _TV_ROWS+=("{$row}")
    done
    _TV_TERM_ROWS=12
    _TV_TERM_COLS=70
    ;;
detail)
    _TV_ROWS=(
        '{"name":"get-command","synopsis":"List every registered command with its type, namespace and the file that defines it","nested":{"k":"a\"b\\c","n":[1,2]},"flag":false,"lines":"line1\nline2","none":null}'
        '{"name":"format-table","synopsis":"Render records","nested":{},"flag":true,"lines":"","none":null}'
    )
    ;;
scrolled)
    _TV_TERM_ROWS=7
    ;;
numeric)
    _TV_ROWS=(
        '{"name":"alpha","size":1200,"ratio":0.5,"tag":null}'
        '{"name":"beta","size":7,"ratio":null,"tag":"x"}'
        '{"name":"gamma","size":null,"ratio":12.25,"tag":""}'
    )
    ;;
markers)
    _TV_TERM_COLS=70
    ;;
scrollbar)
    _TV_ROWS=()
    for i in {1..40}
    do
        _TV_ROWS+=("{\"name\":\"cmd-$i\",\"verb\":\"get\",\"noun\":\"item-$i\",\"namespace\":\"bu\",\"type\":\"source\"}")
    done
    ;;
search_truncated|search_expanded)
    _TV_MAX_WIDTH=10
    ;;
esac
_TV_NUM_ROWS=${#_TV_ROWS[@]}

__bu_tv_extract_columns ""
__bu_tv_rebuild_cache

# Search the way the prompt does: matches, then the first one from the
# cursor row
__tv_search() {
    _TV_SEARCH_QUERY=$1
    __bu_tv_update_search_matches
    if __bu_tv_search_from "$_TV_CUR_ROW" forward
    then
        __bu_tv_goto_match "$_TV_FOUND_IDX"
    fi
}

case $state in
plain)
    ;;
scrolled)
    _TV_CUR_ROW=4
    _TV_CUR_COL=4
    ;;
cursor)
    _TV_CUR_ROW=2
    _TV_CUR_COL=1
    ;;
search)
    __tv_search get
    ;;
search_truncated)
    __tv_search table
    ;;
search_expanded)
    __tv_search table
    _TV_KEY=w
    __bu_tv_dispatch_key
    ;;
regex)
    __tv_search 'm?n'
    ;;
prompt)
    _TV_PROMPT_ACTIVE=true
    _TV_PROMPT_TEXT=/ge
    __tv_search ge
    ;;
detail)
    _TV_CUR_COL=1
    _TV_SEARCH_QUERY=line
    __bu_tv_update_search_matches
    _TV_KEY=$'\x0a'
    __bu_tv_dispatch_key
    ;;
help)
    _TV_KEY=f1
    __bu_tv_dispatch_key
    ;;
nosidebar)
    _TV_SIDEBAR=false
    ;;
sorted)
    __bu_tv_sort_by_column verb desc
    _TV_CUR_COL=3
    ;;
overflow)
    # 9 data rows for 14 columns; the viewport is col06-col11
    _TV_CUR_COL=10
    ;;
paged)
    __bu_tv_clamp_offsets
    _TV_KEY=shift_right
    __bu_tv_dispatch_key
    ;;
scrollbar)
    # Row 26/40: offset 9
    _TV_CUR_ROW=25
    ;;
filter)
    _TV_FILTER_QUERY=source
    __bu_tv_apply_filter
    ;;
numeric)
    _TV_CUR_ROW=1
    ;;
frozen)
    __bu_tv_clamp_offsets
    for key in f shift_right
    do
        _TV_KEY=$key
        __bu_tv_dispatch_key
    done
    ;;
markers)
    _TV_SIDEBAR=false
    __bu_tv_clamp_offsets
    _TV_KEY=f
    __bu_tv_dispatch_key
    _TV_CUR_COL=10
    ;;
hidden)
    _TV_CUR_COL=1
    _TV_KEY=-
    __bu_tv_dispatch_key
    ;;
*)
    echo "unknown state: $state" >&2
    exit 1
    ;;
esac

__bu_tv_clamp_offsets
__bu_tv_render
