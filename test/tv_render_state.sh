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
#   plain    - 5 records, no search, no colors
#   scrolled - same data, row_offset=2 col_offset=1
#   search   - active query "get" with in-cell + row highlighting
#   regex    - active query "a.e" (regex/glob metachars must match literally)
#   nosidebar  - plain, with the column sidebar hidden
#   sorted     - sorted by verb descending, scrolled to col_offset=2
#   overflow   - 14 columns in a 12-row terminal: the sidebar list scrolls

set -u

# Pin the locale: under a non-UTF-8 locale bash measures bytes, so the
# frame (status line │, truncation) would depend on the caller
export LC_ALL=C.UTF-8

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=../bu_entrypoint.sh
source "$DIR"/../bu_entrypoint.sh >/dev/null 2>&1
# shellcheck source=../lib/core/bu_core_tv.sh
source "$DIR"/../lib/core/bu_core_tv.sh

_TV_ROWS=(
    '{"name":"get-command","verb":"get","noun":"command","namespace":"bu","type":"source"}'
    '{"name":"format-table","verb":"format","noun":"table","namespace":"bu","type":"source"}'
    '{"name":"convert-from-asciitable","verb":"convert-from","noun":"asciitable","namespace":"bu","type":"execute"}'
    '{"name":"query-object","verb":"query","noun":"object","namespace":"bu","type":"source"}'
    '{"name":"select-string","verb":"select","noun":"string","namespace":"bu","type":"alias"}'
)
_TV_TERM_ROWS=20
_TV_TERM_COLS=60

if [[ ${1:-plain} == overflow ]]
then
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
fi
_TV_NUM_ROWS=${#_TV_ROWS[@]}

__bu_tv_extract_columns ""
__bu_tv_rebuild_cache

case ${1:-plain} in
plain)
    _TV_ROW_OFFSET=0
    _TV_COL_OFFSET=0
    ;;
scrolled)
    _TV_ROW_OFFSET=2
    _TV_COL_OFFSET=1
    ;;
search)
    _TV_ROW_OFFSET=0
    _TV_COL_OFFSET=0
    _TV_SEARCH_QUERY="get"
    __bu_tv_update_search_matches
    ;;
regex)
    _TV_ROW_OFFSET=0
    _TV_COL_OFFSET=0
    _TV_SEARCH_QUERY="a.e"
    __bu_tv_update_search_matches
    ;;
nosidebar)
    _TV_SIDEBAR=false
    ;;
sorted)
    __bu_tv_sort_by_column verb desc
    _TV_COL_OFFSET=2
    ;;
overflow)
    # 9 data rows for 14 columns; viewport is col06-col11
    _TV_COL_OFFSET=5
    ;;
*)
    echo "unknown state: $1" >&2
    exit 1
    ;;
esac

__bu_tv_clamp_offsets
__bu_tv_render_frame
