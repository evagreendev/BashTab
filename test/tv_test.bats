#!/usr/bin/env bats

# Tests for lib/core/bu_core_tv.sh (bu view-table — interactive table viewer).
#
# Golden-frame tests compare __bu_tv_render output byte-for-byte against
# fixtures captured in test/fixtures/, and anchor each frame on the escape
# sequence that matters with grep -F ("[" is a regex metacharacter).  Both
# the fixtures and the tests are produced by the same driver
# (test/tv_render_state.sh), so the states can't drift.  Regenerate
# fixtures after intentional renderer changes with:
#
#     for s in plain scrolled cursor search search_truncated search_expanded \
#              regex prompt detail help nosidebar sorted overflow paged \
#              scrollbar filter numeric frozen markers hidden; do
#         bash test/tv_render_state.sh "$s" > test/fixtures/tv_frame_$s.expected
#     done
#
# Unit and perf tests run in a child `bash -c`: bats' DEBUG trap inflates
# pure-bash loops ~100x.  Timers use `date +%s%N` (bash 4.4 has no
# EPOCHREALTIME), falling back to EPOCHREALTIME where date lacks %N (BSD).

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # Fixtures and widths are UTF-8, and read -n 1 reads one character only
    # under a UTF-8 locale; don't depend on the caller's locale
    export LC_ALL=C.UTF-8
}

# ===========================================================================
# Golden frames (byte-identity + anchors)
# ===========================================================================

# ```md
# Render a state, byte-compare it with its fixture, and check that every
# anchor occurs in the frame verbatim.
#
# Params:
# - $1: state
# - $@: anchors (exact byte strings)
# ```
function __tv_check_golden {
    local -r state=$1
    shift
    local -r actual=$BATS_TEST_TMPDIR/$state.actual
    bash "$DIR/tv_render_state.sh" "$state" > "$actual"
    cmp "$actual" "$DIR/fixtures/tv_frame_$state.expected"
    local anchor
    for anchor in "$@"; do
        if ! grep -qF -- "$anchor" "$actual"; then
            printf 'anchor missing from %s frame: %q\n' "$state" "$anchor"
            return 1
        fi
    done
}

function test_tv_frame_plain_matches_golden { #@test
    # Cursor row reversed end to end (padding inside the attribute) except
    # its cursor cell (un-reversed, bold, underlined across its width),
    # cursor column header bold+underline, other headers bold, plain rows
    # trimmed
    __tv_check_golden plain \
        $'\e[1;1H\e[1;4mname\e[0m' \
        $'\e[1mverb\e[0m' \
        $'\e[3;1H\e[1;4mget-command            \e[0m\e[7m  get                  \e[0m\e[K' \
        $'\e[4;1Hformat-table             format\e[K' \
        $'\e[20;1H\e[2mRow 1/5 | Col name (1/5) | q:quit /:search s:sort H:help\e[0m\e[K\e[?25l'
}

function test_tv_frame_scrolled_matches_golden { #@test
    # Cursor on the last row/column: the viewport scrolled the minimum.
    # 5 rows overflow the 4 data rows, so a scrollbar narrows the table
    __tv_check_golden scrolled \
        $'\e[1;1H\e[1mnoun\e[0m' \
        $'\e[1;4mtype\e[0m' \
        $'\e[3;1Htable ' \
        $'\e[6;1H\e[7mstring' \
        $'\e[3;46H\e[2m░\e[0m\e[4;46H█' \
        'Row 5/5 | Col type (5/5)'
}

function test_tv_frame_cursor_matches_golden { #@test
    __tv_check_golden cursor \
        $'\e[1;4mverb\e[0m' \
        $'\e[5;1H\e[7mconvert-from-asciitable  \e[0m\e[1;4mconvert-from\e[0m\e[7m         \e[0m\e[K' \
        'Row 3/5 | Col verb (2/5)'
}

function test_tv_frame_search_matches_golden { #@test
    # A hit re-applies the attribute it sits in: the cursor cell's, or the
    # reversed cursor row's
    __tv_check_golden search \
        $'\e[3;1H\e[1;4m\e[43;30mget\e[0m\e[1;4m-command' \
        $'\e[43;30mget\e[0m\e[7m ' \
        '/get 1/1 [name]'
}

function test_tv_frame_search_truncated_matches_golden { #@test
    # Hits hidden by truncation highlight the ellipsis, in and out of the
    # cursor row
    __tv_check_golden search_truncated \
        $'format-\e[43;30mta\e[0m\e[1;4m\e[43;30m…\e[0m\e[1;4m' \
        $'convert-f\e[43;30m…\e[0m  ' \
        $'ascii\e[43;30mtable\e[0m' \
        '/table 1/2 [name]'
}

function test_tv_frame_search_expanded_matches_golden { #@test
    __tv_check_golden search_expanded \
        $'format-\e[43;30mtable\e[0m\e[1;4m' \
        $'convert-from-ascii\e[43;30mtable\e[0m' \
        'Col name (1/5) wide'
}

function test_tv_frame_regex_query_matches_golden { #@test
    # "m?n" must match literally: as a glob it would hit "command", as a
    # regex every "n"
    __tv_check_golden regex '/m?n no match'
    if grep -qF $'\e[43;30m' "$BATS_TEST_TMPDIR/regex.actual"; then
        echo "literal query highlighted something"
        return 1
    fi
}

function test_tv_frame_prompt_matches_golden { #@test
    # Prompt on the status row, terminal cursor shown right after it
    __tv_check_golden prompt \
        $'\e[20;1H/ge\e[K\e[20;4H\e[?25h' \
        $'\e[3;1H\e[1;4m\e[43;30mge\e[0m\e[1;4mt-command'
}

function test_tv_frame_detail_matches_golden { #@test
    # Keys padded to the longest header, cursor column key bold, values
    # word-wrapped under the value column, nested JSON pretty-printed raw,
    # real newlines, false shown, hits highlighted
    __tv_check_golden detail \
        $'\e[1;1H\e[1mRecord 1/2\e[0m\e[K' \
        $'\e[4;1H\e[1msynopsis\e[0m  List every registered command with its type,\e[K' \
        $'\e[5;1H          namespace and the file that defines it\e[K' \
        $'            "k": "a\\"b\\\\c",' \
        $'flag      false\e[K' \
        $'lines     \e[43;30mline\e[0m1\e[K' \
        $'\e[15;1H          \e[43;30mline\e[0m2\e[K' \
        $'\e[16;1Hnone      \e[2m∅\e[0m\e[K'
}

function test_tv_frame_help_matches_golden { #@test
    __tv_check_golden help \
        $'\e[1;1H\e[1mKeys\e[0m\e[K' \
        '0 $ Home End' \
        'Shift-→ Shift-←    page columns right / left' \
        'Lines 1-17/'
}

function test_tv_frame_nosidebar_matches_golden { #@test
    # The columns cut off on the right are counted on the separator row
    __tv_check_golden nosidebar $'\e[3;1H\e[1;4mget-command' \
        $'\e[2;58H\e[1m2 ▸\e[0m'
    if grep -qF 'Columns' "$BATS_TEST_TMPDIR/nosidebar.actual"; then
        echo "sidebar drawn while hidden"
        return 1
    fi
}

function test_tv_frame_sorted_sidebar_matches_golden { #@test
    # The cursor followed get-command through the sort; the sidebar shows
    # the sort arrow, and ▸ and the ⇤ × buttons on the cursor column (its
    # name gives up two cells to them)
    __tv_check_golden sorted \
        $'\e[1;1H\e[1mverb ↓\e[0m' \
        $'\e[5;1H\e[7mget ' \
        $'\e[7m▸namesp… ⇤ ×' \
        $'\e[7m verb      ↓' \
        'Sorted: verb ↓'
}

function test_tv_frame_sidebar_overflow_matches_golden { #@test
    # More columns than data rows: the list scrolls to the viewport with
    # "↑ N more" / "↓ N more" rows (and leaves out the empty Hidden title)
    __tv_check_golden overflow \
        $'\e[1;1H\e[1mcol06\e[0m' \
        $'\e[7m▸co… ⇤ ×' \
        '↑ 4 more' \
        '↓ 3 more'
}

function test_tv_frame_paged_matches_golden { #@test
    # One page right from column 0: col07 is the new left edge and cursor
    __tv_check_golden paged \
        $'\e[1;1H\e[1;4mcol07\e[0m' \
        'Col col07 (7/14)'
}

function test_tv_frame_scrollbar_matches_golden { #@test
    # 40 rows, 17 data rows, offset 9: a 7-row thumb at screen rows 7-13,
    # in the column just left of the sidebar border
    __tv_check_golden scrollbar \
        $'\e[6;46H\e[2m░\e[0m\e[7;46H█' \
        $'\e[13;46H█\e[14;46H\e[2m░\e[0m' \
        $'\e[1;47H│ \e[1mColumns' \
        $'\e[19;1H\e[1;4mcmd-26' \
        'Row 26/40'
    local -i thumb
    thumb=$(grep -o '█' "$BATS_TEST_TMPDIR/scrollbar.actual" | wc -l)
    (( thumb == 7 ))
}

function test_tv_frame_filter_matches_golden { #@test
    __tv_check_golden filter \
        $'\e[3;1H\e[1;4mget-command' \
        $'\e[4;1Hformat-table' \
        $'\e[5;1Hquery-object' \
        $'\e[6;1H\e[K' \
        'Row 1/3 | Col name (1/5) | &source 3/5'
}

function test_tv_frame_numeric_and_null_matches_golden { #@test
    # Numeric columns (and their headers) right-aligned; null is a dim ∅,
    # also inside the cursor row
    __tv_check_golden numeric \
        $'\e[3;1Halpha  1200    0.5  \e[2m∅\e[0m\e[K' \
        $'\e[4;1H\e[1;4mbeta \e[0m\e[7m     7      \e[2m∅\e[0m\e[7m  x' \
        $'\e[5;1Hgamma     \e[2m∅\e[0m  12.25\e[K'
}

function test_tv_frame_frozen_matches_golden { #@test
    # col01 stays on the left, behind a dim divider, while the rest page
    __tv_check_golden frozen \
        $'\e[1;1H\e[1mcol01\e[0m  \e[2m│\e[22m \e[1;4mcol07\e[0m' \
        $'\e[3;1H\e[7mvalue-1\e[2m│\e[22m \e[0m\e[1;4mvalue-1\e[0m\e[7m  value-1' \
        'Col col07 (7/14)'
}

function test_tv_frame_markers_matches_golden { #@test
    # Sidebar hidden: 4 columns off the left (after the frozen one), 3 off
    # the right
    __tv_check_golden markers \
        $'\e[2;10H\e[1m◂ 4\e[0m' \
        $'\e[2;68H\e[1m3 ▸\e[0m' \
        $'\e[1;1H\e[1mcol01\e[0m  \e[2m│\e[22m \e[1mcol06'
}

function test_tv_frame_hidden_matches_golden { #@test
    # The sidebar lists the hidden column, dimmed, under the Hidden title
    __tv_check_golden hidden \
        $'\e[1;1H\e[1mname\e[0m                     \e[1;4mnoun\e[0m' \
        $'\e[7;47H│ \e[2mHidden -----\e[0m' \
        $'\e[8;47H│ \e[2m verb      +\e[0m' \
        'Col noun (2/4) | 1 hidden | +:unhide'
}

function test_tv_frame_independent_of_term { #@test
    # tput sgr0 is \e(B\e[m under xterm, \e[m\017 under screen and empty
    # under dumb; the frame must use raw CSI only.  Each run re-sources the
    # entrypoint, so the tput values are recomputed under that TERM.
    local t
    for t in xterm-256color screen-256color dumb; do
        TERM=$t bash "$DIR/tv_render_state.sh" search > "$BATS_TEST_TMPDIR/search.$t"
    done
    cmp "$BATS_TEST_TMPDIR/search.xterm-256color" "$BATS_TEST_TMPDIR/search.screen-256color"
    cmp "$BATS_TEST_TMPDIR/search.xterm-256color" "$BATS_TEST_TMPDIR/search.dumb"
    cmp "$BATS_TEST_TMPDIR/search.xterm-256color" "$DIR/fixtures/tv_frame_search.expected"
}

# ===========================================================================
# Unit tests (run in a child bash: see the header note)
# ===========================================================================

# ```md
# Run a snippet in a child bash with the viewer loaded and `rows` (JSONL,
# one record per line) loaded into _TV_ROWS with columns extracted.  The
# snippet sees TV_ENTER, TV_CR, TV_BS and TV_CTRL_U holding those keys.
#
# Params:
# - $1: JSONL rows
# - $2: bash snippet to run afterwards
# ```
function __tv_in_child {
    TV_ENTER=$'\n' TV_CR=$'\r' TV_BS=$'\x7f' TV_CTRL_U=$'\x15' bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        mapfile -t _TV_ROWS <<<"$1"
        _TV_NUM_ROWS=${#_TV_ROWS[@]}
        __bu_tv_extract_columns ""
        eval "$2"
    ' _ "$1" "$2"
}

# ```md
# JSONL: N records {"name":"cmd-i"} (1-based), with every name listed in
# the remaining arguments' rows renamed to "hit-i".
#
# Params:
# - $1: number of records
# - $@: 1-based records to rename
# ```
function __tv_rows {
    local -r -i n=$1
    shift
    local -A hit=()
    local i
    for i in "$@"; do hit[$i]=1; done
    for (( i = 1; i <= n; i++ )); do
        if [[ -n "${hit[$i]:-}" ]]; then
            printf '{"name":"hit-%s","version":"1.0"}\n' "$i"
        else
            printf '{"name":"cmd-%s","version":"1.0"}\n' "$i"
        fi
    done
}

# ── Cell cache ───────────────────────────────────────────────────────────

function test_tv_cache_empty_cells_stay_aligned { #@test
    # IFS=$'\t' read would collapse consecutive and trailing tabs
    local result
    result=$(__tv_in_child \
        '{"id":1,"name":"","note":"x"}
{"id":2,"name":"b\tc","note":""}
{"id":"","name":null,"note":""}' \
        '__bu_tv_rebuild_cache; echo "rc=$?"; printf "%s|" "${#_TV_CELLS[@]}" "${_TV_CELLS[@]}"; echo; echo "${_TV_COL_WIDTHS[*]}"')
    # null is the lone-U+0002 marker, "" stays empty
    assert_equal "$result" $'rc=0\n9|1||x|2|b\\tc|||\x02||\n4 4 4'
}

function test_tv_cache_single_column_empty_value { #@test
    # A row-level @tsv | split("\t") would turn "" into [] and lose the cell
    local result
    result=$(__tv_in_child '{"a":"x"}
{"a":""}' \
        '__bu_tv_rebuild_cache; echo "rc=$?"; printf "%s|" "${#_TV_CELLS[@]}" "${_TV_CELLS[@]}"')
    assert_equal "$result" 'rc=0
2|x||'
}

function test_tv_cache_literal_u0001_is_escaped { #@test
    local result
    result=$(__tv_in_child '{"a":"p\u0001q","b":"r"}' \
        '__bu_tv_rebuild_cache; echo "rc=$?"; printf "%s|" "${#_TV_CELLS[@]}" "${_TV_CELLS[@]}"; echo; echo "${_TV_COL_WIDTHS[*]}"')
    assert_equal "$result" 'rc=0
2|p\u0001q|r|
8 4'
}

function test_tv_cache_false_and_zero_render { #@test
    # `. // ""` treats false like null; only null is the null marker
    local result
    result=$(__tv_in_child '{"b":false,"t":true,"z":0,"n":null,"s":""}' \
        '__bu_tv_rebuild_cache; printf "%s|" "${_TV_CELLS[@]}"')
    assert_equal "$result" $'false|true|0|\x02||'
}

function test_tv_cache_numeric_columns_and_null_marker { #@test
    # A column is numeric when every non-null value is a number; a literal
    # U+0002 is escaped so it can't pass for null
    local result
    result=$(__tv_in_child '{"n":1,"m":"1","x":null,"y":2.5,"s":"a\u0002b"}
{"n":null,"m":2,"x":null,"y":-3,"s":""}' \
        '__bu_tv_rebuild_cache; echo "${_TV_COL_NUMERIC[*]}"; printf "%q " "${_TV_CELLS[@]}"; echo
        printf "%q " "${_TV_ROW_TEXT[@]}"')
    assert_equal "$result" "1 0 0 1 0
1 1 \$'\\002' 2.5 a\\\\u0002b \$'\\002' 2 \$'\\002' -3 '' 
\$'1\\0011\\001\\0012.5\\001a\\\\u0002b' \$'\\0012\\001\\001-3\\001' "
}

function test_tv_cache_row_text_is_ansi_stripped { #@test
    local result
    result=$(__tv_in_child '{"a":"\u001b[31mred\u001b[0m","b":"x"}' \
        '__bu_tv_rebuild_cache; printf "%q " "${_TV_ROW_TEXT[@]}"; echo "${_TV_COL_FULL_WIDTHS[*]}"')
    assert_equal "$result" "\$'red\\001x' 3 1"
}

function test_tv_cache_count_mismatch_refuses { #@test
    # A shifted parse must clear the cache and fail rather than render
    local result
    result=$(__tv_in_child '{"a":1,"b":2}
{"a":3,"b":4}' \
        'fake_jq() { printf "4 4\n1\x012\x01.\n"; }
        BU_OUT_JQ=fake_jq
        __bu_tv_rebuild_cache 2>/dev/null; echo "rc=$? cells=${#_TV_CELLS[@]} widths=${#_TV_COL_WIDTHS[@]} text=${#_TV_ROW_TEXT[@]}"')
    assert_equal "$result" 'rc=1 cells=0 widths=0 text=0'
}

function test_tv_truncated_header_not_over_padded { #@test
    # A truncated header is exactly col_w characters: the ellipsis occupies
    # the last cell, no padding follows
    local result
    # String values: numeric columns would right-align the headers
    result=$(__tv_in_child '{"abcdefghij":"x","b":"y"}' \
        '__bu_tv_rebuild_cache
        _TV_COL_WIDTHS=(6 4)
        __bu_tv_compute_visible_cols
        __bu_tv_render_line -1 "" line
        __bu_tv_strip_ansi line
        printf "[%s]" "$line"')
    assert_equal "$result" '[abcde…  b]'
}

function test_tv_colors_auto_none_and_empty { #@test
    local result
    result=$(__tv_in_child '{"name":1,"version":2}' \
        '__bu_tv_build_colors auto; echo "auto=${#_TV_COLORS[@]}"
        __bu_tv_build_colors none; echo "none=${#_TV_COLORS[@]}"
        __bu_tv_build_colors ""; echo "empty=${#_TV_COLORS[@]}"')
    assert_equal "$result" 'auto=2
none=0
empty=0'
}

function test_tv_cursor_cell_drawn_in_its_own_attribute { #@test
    # The cursor cell leaves the reversed row with explicit resets, its
    # underline spans its padding (also for an empty cell), and a coloured
    # cell re-applies the cell attribute after its colour
    local result
    result=$(__tv_in_child '{"a":"x","b":"","c":"zz"}' '
        __bu_tv_rebuild_cache; _TV_SIDEBAR=false; _TV_TERM_COLS=20; __bu_tv_compute_widths
        _TV_COLORS[c]=$'"'"'\e[32m'"'"'
        for c in 0 1 2; do
            _TV_CUR_COL=$c; __bu_tv_clamp_offsets; __bu_tv_compute_visible_cols
            __bu_tv_render_line 0 $'"'"'\e[7m'"'"' line; printf "%q\n" "$line"
        done')
    assert_equal "$result" "\$'\\E[1;4mx   \\E[0m\\E[7m        \\E[32mzz\\E[0m\\E[7m      \\E[0m'
\$'\\E[7mx     \\E[0m\\E[1;4m    \\E[0m\\E[7m  \\E[32mzz\\E[0m\\E[7m      \\E[0m'
\$'\\E[7mx           \\E[0m\\E[1;4m\\E[32mzz\\E[0m\\E[1;4m  \\E[0m\\E[7m    \\E[0m'"
}

function test_tv_cursor_row_reapplies_attr_after_color { #@test
    # After a cell colour's reset the row attribute comes back; a hit
    # re-applies reset + row attribute + colour
    local result
    result=$(__tv_in_child '{"a":"xay","b":"z"}' \
        '__bu_tv_rebuild_cache
        _TV_COLORS[a]=$'"'"'\e[31m'"'"'
        _TV_SEARCH_QUERY=a; __bu_tv_query_prepare
        __bu_tv_format_cell 0 0 $'"'"'\e[7m'"'"'; printf "%q\n" "$_TV_FC_TEXT"
        __bu_tv_format_cell 0 1 $'"'"'\e[7m'"'"'; printf "%q\n" "$_TV_FC_TEXT"
        __bu_tv_format_cell 0 0 ""; printf "%q\n" "$_TV_FC_TEXT"')
    assert_equal "$result" "\$'\\E[31mx\\E[43;30ma\\E[0m\\E[7m\\E[31my\\E[0m\\E[7m'
z
\$'\\E[31mx\\E[43;30ma\\E[0m\\E[31my\\E[0m'"
}

function test_tv_producer_ansi_matched_on_stripped_text { #@test
    # A one-letter query must not match (or highlight) inside \e[31m;
    # without a query the producer's colours are kept, its resets re-apply
    # the cursor row attribute
    local result
    result=$(__tv_in_child '{"a":"\u001b[31mxyz\u001b[0m","b":"m"}' \
        '__bu_tv_rebuild_cache
        _TV_SEARCH_QUERY=m; __bu_tv_update_search_matches
        echo "rows=${_TV_MATCHED_ROWS[*]} cols=${_TV_MATCHED_COLS[*]}"
        __bu_tv_format_cell 0 0 ""; printf "%q\n" "$_TV_FC_TEXT"
        __bu_tv_search_clear; __bu_tv_query_prepare
        __bu_tv_format_cell 0 0 $'"'"'\e[7m'"'"'; printf "%q %s\n" "$_TV_FC_TEXT" "$_TV_FC_VIS_LEN"')
    assert_equal "$result" "rows=0 cols=1
xyz
\$'\\E[31mxyz\\E[0m\\E[7m' 3"
}

# ── Layout and sidebar ───────────────────────────────────────────────────

function test_tv_sidebar_layout_reserves_width { #@test
    local result
    result=$(__tv_in_child '{"name":1,"version":2}' \
        '__bu_tv_rebuild_cache
        _TV_TERM_COLS=80; __bu_tv_update_layout; echo "$_TV_SIDEBAR_W $_TV_TABLE_COLS"
        _TV_SIDEBAR=false; __bu_tv_update_layout; echo "$_TV_SIDEBAR_W $_TV_TABLE_COLS"')
    # "│ " + marker + "version" + " ↑" = 12
    assert_equal "$result" '12 68
0 80'
}

function test_tv_sidebar_hidden_on_narrow_terminal { #@test
    # The table must keep room for its widest column (here 40) + gap; narrow
    # columns leave the sidebar room on a narrow terminal
    local result
    result=$(__tv_in_child '{"name":"'"$(printf 'x%.0s' {1..45})"'","version":2}' \
        '_TV_TERM_COLS=53; __bu_tv_rebuild_cache; __bu_tv_update_layout; echo "$_TV_SIDEBAR_W $_TV_TABLE_COLS"
        _TV_TERM_COLS=54; __bu_tv_compute_widths; __bu_tv_update_layout; echo "$_TV_SIDEBAR_W $_TV_TABLE_COLS"')
    assert_equal "$result" '0 53
12 42'
    result=$(__tv_in_child '{"name":1,"version":2}' \
        '_TV_TERM_COLS=30; __bu_tv_rebuild_cache; __bu_tv_update_layout; echo "$_TV_SIDEBAR_W $_TV_TABLE_COLS"')
    assert_equal "$result" '12 18'
}

function test_tv_sidebar_toggle_reclamps_columns { #@test
    # With the sidebar hidden, the freed width brings more columns into view
    local result
    result=$(__tv_in_child '{"aaaaaaaaaaaaaaaaaaaa":1,"bbbbbbbbbbbbbbbbbbbb":2,"cccccccccccccccccccc":3}' \
        '__bu_tv_rebuild_cache
        _TV_TERM_COLS=80; __bu_tv_clamp_offsets
        __bu_tv_compute_visible_cols; echo "${_TV_VIS_COLS[*]}"
        _TV_KEY=c; __bu_tv_dispatch_key
        __bu_tv_compute_visible_cols; echo "$_TV_SIDEBAR ${_TV_VIS_COLS[*]}"')
    assert_equal "$result" '0 1
false 0 1 2'
}

# ── Cursor clamp ─────────────────────────────────────────────────────────

function test_tv_clamp_rows_scroll_minimum { #@test
    # 10 data rows: the offset moves only as far as the cursor needs, and
    # never leaves blank rows under the last record
    local result
    result=$(__tv_in_child "$(__tv_rows 50)" '
        __bu_tv_rebuild_cache
        _TV_TERM_ROWS=13
        show() { __bu_tv_clamp_offsets; printf "%s/%s " "$_TV_CUR_ROW" "$_TV_ROW_OFFSET"; }
        _TV_CUR_ROW=25; show
        _TV_CUR_ROW=20; show
        _TV_CUR_ROW=3; show
        _TV_CUR_ROW=99; show
        _TV_CUR_ROW=-5; show
        _TV_CUR_ROW=47; _TV_ROW_OFFSET=45; show
        _TV_TERM_ROWS=103; _TV_CUR_ROW=30; show')
    assert_equal "$result" '25/16 20/16 3/3 49/40 0/0 47/40 30/0 '
}

function test_tv_clamp_columns_walk_right_then_left { #@test
    # 14 columns of 7 (+2 gap), 60-column table area beside a 10-wide sidebar
    local row= sep= c
    for c in {01..14}; do row+="$sep\"col$c\":\"value-1\""; sep=,; done
    local result
    result=$(__tv_in_child "{$row}" '
        _TV_TERM_COLS=70; __bu_tv_rebuild_cache
        show() { __bu_tv_clamp_offsets; printf "%s/%s " "$_TV_CUR_COL" "$_TV_COL_OFFSET"; }
        show; echo "table=$_TV_TABLE_COLS"
        _TV_CUR_COL=10; show
        _TV_CUR_COL=7; show
        _TV_CUR_COL=13; show
        _TV_CUR_COL=2; show
        _TV_CUR_COL=99; show
        _TV_CUR_COL=-1; show')
    assert_equal "$result" '0/0 table=60
10/5 7/5 13/8 2/2 13/8 0/0 '
}

# ── Column widths ────────────────────────────────────────────────────────

function test_tv_widths_cap_toggle_and_expand_all { #@test
    local long
    long=$(printf 'x%.0s' {1..50})
    local result
    result=$(__tv_in_child '{"a":"'"$long"'","b":"yyyyyy"}' '
        _TV_TERM_COLS=80; __bu_tv_rebuild_cache; __bu_tv_clamp_offsets
        echo "${_TV_COL_WIDTHS[*]}"
        _TV_KEY=w; __bu_tv_dispatch_key; __bu_tv_render_status
        echo "${_TV_COL_WIDTHS[*]} ${_TV_COL_EXPANDED[*]}"; [[ $_TV_STATUS == *"Col a (1/2) wide |"* ]] && echo wide-status
        _TV_TERM_COLS=30; __bu_tv_compute_widths; echo "${_TV_COL_WIDTHS[*]}"
        _TV_TERM_COLS=80
        _TV_KEY=W; __bu_tv_dispatch_key; echo "${_TV_COL_WIDTHS[*]} ${_TV_COL_EXPANDED[*]}"
        _TV_KEY=W; __bu_tv_dispatch_key; echo "${_TV_COL_WIDTHS[*]} ${_TV_COL_EXPANDED[*]}"
        _TV_KEY=w; __bu_tv_dispatch_key; _TV_KEY=w; __bu_tv_dispatch_key; echo "${_TV_COL_WIDTHS[*]} ${_TV_COL_EXPANDED[*]}"
        _TV_MAX_WIDTH=5; __bu_tv_compute_widths; echo "${_TV_COL_WIDTHS[*]}"
        _TV_MAX_WIDTH=2; __bu_tv_compute_widths; echo "${_TV_COL_WIDTHS[*]}"
        _TV_MAX_WIDTH=100; _TV_TERM_COLS=40; __bu_tv_compute_widths; echo "${_TV_COL_WIDTHS[*]}"')
    assert_equal "$result" '40 6
50 6 true
wide-status
28 6
50 6 true true
40 6 false false
40 6 false false
5 5
4 4
38 6'
}

# ── Search ───────────────────────────────────────────────────────────────

function test_tv_search_smart_case_and_matched_cols { #@test
    local result
    result=$(__tv_in_child '{"a":"Foo","b":"foo"}
{"a":"x","b":"FOO bar"}
{"a":"a.b","b":"a*b"}' '
        __bu_tv_rebuild_cache
        for q in foo Foo FOO "a*b" "a?b" "."; do
            _TV_SEARCH_QUERY=$q; __bu_tv_update_search_matches
            echo "$q: rows=${_TV_MATCHED_ROWS[*]} cols=${_TV_MATCHED_COLS[*]} cur=$_TV_CUR_ROW"
        done')
    assert_equal "$result" 'foo: rows=0 1 cols=0 1 cur=0
Foo: rows=0 cols=0 cur=0
FOO: rows=1 cols=1 cur=0
a*b: rows=2 cols=1 cur=0
a?b: rows= cols= cur=0
.: rows=2 cols=0 cur=0'
}

function test_tv_search_n_and_N_are_position_based_and_centre { #@test
    # Matches at rows 4, 49, 94 (0-based); 10 data rows.  An off-screen
    # match is centred (offset = row - 5, clamped); a visible one isn't
    local result
    result=$(__tv_in_child "$(__tv_rows 100 5 50 95)" '
        __bu_tv_rebuild_cache
        _TV_TERM_ROWS=13; __bu_tv_clamp_offsets
        _TV_SEARCH_QUERY=hit; __bu_tv_update_search_matches
        step() { _TV_KEY=$1; __bu_tv_dispatch_key; __bu_tv_search_status
            printf "%s:%s/%s %s\n" "$1" "$_TV_CUR_ROW" "$_TV_ROW_OFFSET" "$_TV_SEARCH_STATUS"; }
        step n; step n; step n; step n; step N; step N
        _TV_CUR_ROW=52; __bu_tv_clamp_offsets; step N
        _TV_CUR_ROW=49; _TV_ROW_OFFSET=40; __bu_tv_clamp_offsets; step n')
    assert_equal "$result" 'n:4/0 /hit 1/3 [name]
n:49/44 /hit 2/3 [name]
n:94/89 /hit 3/3 [name]
n:4/0 /hit 1/3 [name]
N:94/89 /hit 3/3 [name]
N:49/44 /hit 2/3 [name]
N:49/44 /hit 2/3 [name]
n:94/89 /hit 3/3 [name]'
}

function test_tv_search_status_variants { #@test
    local result
    result=$(__tv_in_child "$(__tv_rows 20 3 7)" '
        __bu_tv_rebuild_cache
        _TV_SEARCH_QUERY=hit; __bu_tv_update_search_matches; __bu_tv_search_status; echo "$_TV_SEARCH_STATUS"
        _TV_SEARCH_QUERY=hit-3; __bu_tv_update_search_matches; __bu_tv_search_status; echo "$_TV_SEARCH_STATUS"
        _TV_SEARCH_QUERY=zzz; __bu_tv_update_search_matches; __bu_tv_search_status; echo "$_TV_SEARCH_STATUS"
        _TV_SEARCH_QUERY=hit; __bu_tv_update_search_matches; _TV_KEY=n; __bu_tv_dispatch_key
        __bu_tv_search_status; echo "$_TV_SEARCH_STATUS"
        _TV_KEY=j; __bu_tv_dispatch_key; __bu_tv_search_status; echo "$_TV_SEARCH_STATUS"')
    assert_equal "$result" '/hit 2 matches
/hit-3 1 match
/zzz no match
/hit 1/2 [name]
/hit 2 matches'
}

function test_tv_sort_keeps_cursor_on_record_with_query { #@test
    # update_search_matches never moves the cursor: after a sort with an
    # active query the cursor stays on its record
    local result
    result=$(__tv_in_child '{"k":3,"s":"c"}
{"k":1,"s":"a"}
{"k":2,"s":"b"}
{"k":4,"s":"d"}' '
        __bu_tv_rebuild_cache; __bu_tv_clamp_offsets
        _TV_SEARCH_QUERY=a; __bu_tv_update_search_matches
        _TV_CUR_ROW=2
        _TV_KEY=s; __bu_tv_dispatch_key
        echo "cur=$_TV_CUR_ROW rec=${_TV_ROWS[_TV_CUR_ROW]} matches=${_TV_MATCHED_ROWS[*]}"
        _TV_KEY=S; __bu_tv_dispatch_key
        echo "cur=$_TV_CUR_ROW rec=${_TV_ROWS[_TV_CUR_ROW]} matches=${_TV_MATCHED_ROWS[*]} $_TV_SORT_DIR"')
    assert_equal "$result" 'cur=1 rec={"k":2,"s":"b"} matches=0
cur=2 rec={"k":2,"s":"b"} matches=3 desc'
}

# ── Search prompt (stubbed key reader) ──────────────────────────────────

# Snippet prefix: __tv_keys drives __bu_tv_read_key (EOF -> tty EOF) and
# every render appends "prompt|query|cur_row|row_offset" to __tv_frames
__TV_PROMPT_STUBS='
    __tv_keys=(); __tv_ki=0; __tv_frames=()
    __bu_tv_read_key() {
        _TV_KEY=${__tv_keys[__tv_ki]:-EOF}
        __tv_ki=$((__tv_ki + 1))
        if [[ $_TV_KEY == EOF ]]; then _TV_EOF=true; _TV_KEY=q; fi
        return 0
    }
    __bu_tv_render() {
        __tv_frames+=("$_TV_PROMPT_TEXT|$_TV_SEARCH_QUERY|$_TV_CUR_ROW|$_TV_ROW_OFFSET")
    }
    __tv_report() {
        printf "%s\n" "${__tv_frames[@]}"
        echo "end:$_TV_PROMPT_ACTIVE|$_TV_SEARCH_QUERY|$_TV_CUR_ROW|$_TV_ROW_OFFSET|quit=$_TV_QUIT"
    }
    __bu_tv_rebuild_cache
    _TV_TERM_ROWS=13
    _TV_CUR_ROW=3; __bu_tv_clamp_offsets
'

function test_tv_prompt_incremental_commit { #@test
    # Each keystroke re-searches from the row the search began on (3): "2"
    # finds cmd-12 (off screen, centred), "25" finds cmd-25
    local result
    result=$(__tv_in_child "$(__tv_rows 30)" "$__TV_PROMPT_STUBS"'
        __tv_keys=(2 5 "$TV_ENTER")
        __bu_tv_prompt /
        __tv_report')
    assert_equal "$result" '/||3|0
/2|2|11|6
/25|25|24|19
end:false|25|24|19|quit=false'
}

function test_tv_prompt_backspace_and_named_keys { #@test
    # Named keys (up, page_down) are ignored, not appended, and don't
    # redraw; "none" (a trap fired) redraws
    local result
    result=$(__tv_in_child "$(__tv_rows 30)" "$__TV_PROMPT_STUBS"'
        __tv_keys=(2 up none 5 page_down "$TV_BS" "$TV_ENTER")
        __bu_tv_prompt /
        __tv_report')
    assert_equal "$result" '/||3|0
/2|2|11|6
/2|2|11|6
/25|25|24|19
/2|2|11|6
end:false|2|11|6|quit=false'
}

function test_tv_prompt_escape_restores_previous_search { #@test
    local result
    result=$(__tv_in_child "$(__tv_rows 30)" "$__TV_PROMPT_STUBS"'
        _TV_SEARCH_QUERY=cmd-3; __bu_tv_update_search_matches
        _TV_CUR_ROW=5; _TV_ROW_OFFSET=2; __bu_tv_clamp_offsets
        __tv_keys=(9 escape)
        __bu_tv_prompt /
        __tv_report; echo "matches=${#_TV_MATCHED_ROWS[@]}"')
    assert_equal "$result" '/|cmd-3|5|2
/9|9|8|2
end:false|cmd-3|5|2|quit=false
matches=2'
}

function test_tv_prompt_ctrl_u_clears_and_empty_enter_restores { #@test
    # Ctrl-U empties the query: the previous search and position come back
    # while typing; Enter on an empty query keeps them
    local result
    result=$(__tv_in_child "$(__tv_rows 30)" "$__TV_PROMPT_STUBS"'
        _TV_SEARCH_QUERY=cmd-3; __bu_tv_update_search_matches
        __tv_keys=(2 9 "$TV_CTRL_U" "$TV_ENTER")
        __bu_tv_prompt "?"
        __tv_report')
    assert_equal "$result" '?|cmd-3|3|0
?2|2|1|0
?29|29|28|20
?|cmd-3|3|0
end:false|cmd-3|3|0|quit=false'
}

function test_tv_prompt_eof_cancels_and_quits { #@test
    # read_key maps tty EOF to the printable "q": without _TV_EOF the
    # prompt would append q forever
    local result
    result=$(__tv_in_child "$(__tv_rows 30)" "$__TV_PROMPT_STUBS"'
        __tv_keys=(2)
        __bu_tv_prompt /
        __tv_report')
    assert_equal "$result" '/||3|0
/2|2|11|6
end:false||3|0|quit=true'
}

function test_tv_prompt_backward_searches_at_or_before_start { #@test
    local result
    result=$(__tv_in_child "$(__tv_rows 30)" "$__TV_PROMPT_STUBS"'
        _TV_CUR_ROW=15; __bu_tv_clamp_offsets
        __tv_keys=(2 "$TV_ENTER")
        __bu_tv_prompt "?"
        __tv_report')
    assert_equal "$result" '?||15|6
?2|2|11|6
end:false|2|11|6|quit=false'
}

# ── Column paging ────────────────────────────────────────────────────────

# 14 columns col01..col14, every cell "value-1" (7 wide, 9 with the gap)
function __tv_wide_row {
    local row= sep= c
    for c in {01..14}; do row+="$sep\"col$c\":\"value-1\""; sep=,; done
    printf '{%s}' "$row"
}

function test_tv_page_columns_right_and_left { #@test
    # Terminal 70, sidebar 10: a 60-column table area holds 6 columns
    local result
    result=$(__tv_in_child "$(__tv_wide_row)" '
        _TV_TERM_COLS=70; __bu_tv_rebuild_cache; __bu_tv_clamp_offsets
        show() { printf "%s/%s," "$_TV_COL_OFFSET" "$_TV_CUR_COL"; }
        echo "table=$_TV_TABLE_COLS"
        __bu_tv_page_cols_right; show
        __bu_tv_page_cols_right; show
        __bu_tv_page_cols_right; show
        __bu_tv_page_cols_left; show
        __bu_tv_page_cols_left; show
        __bu_tv_page_cols_left; show; echo
        _TV_KEY="\$"; __bu_tv_dispatch_key; echo "dollar=$_TV_CUR_COL"
        _TV_KEY=0; __bu_tv_dispatch_key; echo "zero=$_TV_CUR_COL"
        _TV_KEY=shift_right; __bu_tv_dispatch_key; show; echo
        _TV_KEY=shift_left; __bu_tv_dispatch_key; show; echo')
    # The last step: from offset 6, column 6 becomes the rightmost, so
    # columns 1..6 fill the 60
    assert_equal "$result" 'table=60
6/6,8/12,8/13,3/3,0/0,0/0,
dollar=13
zero=0
6/6,
1/1,'
}

function test_tv_page_columns_without_sidebar { #@test
    # 70 table columns hold 7
    local result
    result=$(__tv_in_child "$(__tv_wide_row)" '
        _TV_TERM_COLS=70; _TV_SIDEBAR=false; __bu_tv_rebuild_cache; __bu_tv_clamp_offsets
        __bu_tv_page_cols_right; echo "$_TV_TABLE_COLS $_TV_COL_OFFSET/$_TV_CUR_COL"')
    assert_equal "$result" '70 7/7'
}

function test_tv_page_columns_left_over_wide { #@test
    # Columns of 50 x capped at 40 cannot share a 50-column screen: page
    # left still moves one column instead of sticking
    local x
    x=$(printf 'x%.0s' {1..50})
    local result
    result=$(__tv_in_child '{"a":"'"$x"'","b":"'"$x"'","c":"'"$x"'"}' '
        _TV_TERM_COLS=50; __bu_tv_rebuild_cache
        _TV_CUR_COL=2; __bu_tv_clamp_offsets; printf "%s/%s " "$_TV_COL_OFFSET" "$_TV_CUR_COL"
        __bu_tv_page_cols_left; printf "%s/%s " "$_TV_COL_OFFSET" "$_TV_CUR_COL"
        __bu_tv_page_cols_left; printf "%s/%s" "$_TV_COL_OFFSET" "$_TV_CUR_COL"')
    assert_equal "$result" '2/2 1/1 0/0'
}

function test_tv_page_rows_move_cursor_and_viewport { #@test
    # Space/b, PgDn/PgUp and Shift-↓/↑ page cursor and viewport; Ctrl-D/U
    # move the cursor half a page
    local result
    result=$(__tv_in_child "$(__tv_rows 50)" '
        __bu_tv_rebuild_cache; _TV_TERM_ROWS=13; __bu_tv_clamp_offsets
        for k in " " shift_down page_down $'"'"'\x04'"'"' b shift_up page_up $'"'"'\x15'"'"' G g; do
            _TV_KEY=$k; __bu_tv_dispatch_key; printf "%s/%s " "$_TV_CUR_ROW" "$_TV_ROW_OFFSET"
        done')
    assert_equal "$result" '10/10 20/20 30/30 35/30 25/20 15/10 5/0 0/0 49/40 0/0 '
}

# ── Status line ──────────────────────────────────────────────────────────

function test_tv_status_hints_degrade_whole { #@test
    local result
    result=$(__tv_in_child "$(__tv_rows 5)" '
        __bu_tv_rebuild_cache
        for w in 120 60 40 20; do
            _TV_TERM_COLS=$w; __bu_tv_render_status
            s=$_TV_STATUS; __bu_tv_strip_ansi s; echo "[$s]"
        done')
    # Words drop from the right, H:help last
    assert_equal "$result" '[Row 1/5 | Col name (1/2) | q:quit /:search s:sort w:wide Enter:detail m:mouse &:filter H:help]
[Row 1/5 | Col name (1/2) | q:quit /:search s:sort H:help]
[Row 1/5 | Col name (1/2) | H:help]
[Row 1/5 | Col name ]'
}

function test_tv_status_hints_follow_state { #@test
    # The keys that undo or follow up the current state lead the hints:
    # + with hidden columns, n/N with search matches (not with no match),
    # Esc with a search or a filter
    local result
    result=$(__tv_in_child "$(__tv_rows 30)" '
        __bu_tv_rebuild_cache; _TV_TERM_COLS=200
        h() { __bu_tv_render_status; s=$_TV_STATUS; __bu_tv_strip_ansi s; echo "${s##* | }"; }
        _TV_KEY=-; __bu_tv_dispatch_key; h
        _TV_KEY=+; __bu_tv_dispatch_key
        _TV_SEARCH_QUERY=zzz; __bu_tv_update_search_matches; h
        _TV_SEARCH_QUERY=cmd-2; __bu_tv_update_search_matches; h
        _TV_KEY=escape; __bu_tv_dispatch_key
        __bu_tv_filter_to 2 -1 0; h
        _TV_KEY=escape; __bu_tv_dispatch_key; h')
    assert_equal "$result" '+:unhide q:quit /:search s:sort w:wide Enter:detail m:mouse &:filter H:help
Esc:clear q:quit /:search s:sort w:wide Enter:detail m:mouse &:filter H:help
n/N:match Esc:clear q:quit /:search s:sort w:wide Enter:detail m:mouse &:filter H:help
Esc:clear q:quit /:search s:sort w:wide Enter:detail m:mouse &:filter H:help
q:quit /:search s:sort w:wide Enter:detail m:mouse &:filter H:help'
}

# ── Overlays ─────────────────────────────────────────────────────────────

function test_tv_overlay_key_routing { #@test
    # 20 columns: the detail overlay has 20 lines for 10 data rows
    local rows= r c sep
    for r in 1 2 3; do
        sep=; printf -v row '{'
        for c in {01..20}; do
            row+="$sep\"c$c\":\"r$r-$c\""; sep=,
        done
        rows+="$row}"$'\n'
    done
    local result
    result=$(__tv_in_child "${rows%$'\n'}" '
        __bu_tv_rebuild_cache; _TV_TERM_ROWS=13; __bu_tv_clamp_offsets
        k() { _TV_KEY=$1; __bu_tv_dispatch
            printf "%s:%s r%s d%s h%s\n" "$2" "$_TV_MODE" "$_TV_CUR_ROW" "$_TV_DETAIL_OFFSET" "$_TV_HELP_OFFSET"; }
        k "$TV_ENTER" enter; k j j; k G G; k g g; k " " space; k b b; k shift_down sdown
        k J J; k J J; k J J; k K K
        _TV_SEARCH_QUERY=r3-; __bu_tv_update_search_matches
        k n n; k N N
        k H H; k j hj; k q hq; k f1 f1; k escape hesc
        k q q; k f1 tf1; k "$TV_ENTER" henter
        k "$TV_ENTER" enter2; _TV_EOF=true; k q eof; echo "quit=$_TV_QUIT"')
    assert_equal "$result" 'enter:detail r0 d0 h0
j:detail r0 d1 h0
G:detail r0 d10 h0
g:detail r0 d0 h0
space:detail r0 d10 h0
b:detail r0 d0 h0
sdown:detail r0 d10 h0
J:detail r1 d0 h0
J:detail r2 d0 h0
J:detail r2 d0 h0
K:detail r1 d0 h0
n:detail r2 d0 h0
N:detail r2 d0 h0
H:help r2 d0 h0
hj:help r2 d0 h1
hq:detail r2 d0 h1
f1:help r2 d0 h0
hesc:detail r2 d0 h0
q:table r2 d0 h0
tf1:help r2 d0 h0
henter:table r2 d0 h0
enter2:detail r2 d0 h0
eof:detail r2 d0 h0
quit=true'
}

function test_tv_detail_values_from_raw_record { #@test
    # One jq pass over the raw record: strings raw with real newlines,
    # other types pretty-printed, false shown, null empty
    local result
    result=$(__tv_in_child '{"o":{"k":"a\"b\\c"},"l":"line1\nline2","f":false,"n":null,"s":"x\ty"}' '
        __bu_tv_rebuild_cache
        __bu_tv_detail_values 0
        printf "<%s>\n" "${_TV_DETAIL_VALUES[@]}"')
    assert_equal "$result" '<{
  "k": "a\"b\\c"
}>
<line1
line2>
<false>
<>
<x	y>'
}

function test_tv_detail_values_fall_back_to_cache { #@test
    local result
    result=$(__tv_in_child '{"a":"p\nq","b":2}' '
        __bu_tv_rebuild_cache
        fake_jq() { printf "only\n\x01\n"; }
        BU_OUT_JQ=fake_jq
        __bu_tv_detail_values 0
        printf "<%s>" "${_TV_DETAIL_VALUES[@]}"')
    assert_equal "$result" '<p\nq><2>'
}

function test_tv_detail_lines_wrap_and_indent { #@test
    local result
    result=$(__tv_in_child '{"id":"x","description":"alpha beta gamma delta epsilon","l":"one\ntwo"}' '
        __bu_tv_rebuild_cache; _TV_TERM_COLS=30; _TV_CUR_COL=1
        __bu_tv_build_detail
        for line in "${_TV_DETAIL_LINES[@]}"; do __bu_tv_strip_ansi line; echo "[$line]"; done
        echo "first=${_TV_DETAIL_COL_LINE[*]}"
        [[ ${_TV_DETAIL_LINES[1]} == $'"'"'\e[1mdescription\e[0m'"'"'* ]] && echo bold-key')
    assert_equal "$result" '[id           x]
[description  alpha beta gamma]
[             delta epsilon]
[l            one]
[             two]
first=0 1 3
bold-key'
}

function test_tv_help_lines_fit_60_columns { #@test
    local result
    result=$(__tv_in_child '{"a":1}' '
        for line in "${__BU_TV_HELP_LINES[@]}"; do
            (( ${#line} > 60 )) && echo "too long (${#line}): $line"
        done
        echo "${#__BU_TV_HELP_LINES[@]} lines"')
    [[ "$result" =~ ^[0-9]+\ lines$ ]] || { echo "$result"; return 1; }
}

# ── Mouse ────────────────────────────────────────────────────────────────

function test_tv_read_key_sgr_mouse_reports { #@test
    local -a seqs=('\e[<0;5;7M' '\e[<0;5;7m' '\e[<32;3;4M' '\e[<64;1;1M'
        '\e[<65;1;1M' '\e[<4;5;7M' '\e[<2;120;30M')
    local -a want=('press 0 5 7' 'release 0 5 7' 'drag 0 3 4' 'wheel_up 0 1 1'
        'wheel_down 1 1 1' 'press 0 5 7' 'press 2 120 30')
    local -i i
    local result
    for i in "${!seqs[@]}"; do
        result=$(printf "${seqs[i]}" | bash -c '
            source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
            source "'"$DIR"'/../lib/core/bu_core_tv.sh"
            __bu_tv_read_key 1
            printf "%s %s %s %s %s" "$_TV_KEY" "$_TV_MOUSE_EVENT" "$_TV_MOUSE_BUTTON" "$_TV_MOUSE_X" "$_TV_MOUSE_Y"
        ')
        assert_equal "$result" "mouse ${want[i]}"
    done
}

function test_tv_read_key_malformed_mouse_is_noop { #@test
    # A body without x;y (final byte consumed), and one past the 24-byte cap
    local result
    result=$(printf '\e[<0;5Mj\e[<1111111111111111111111111111;1;1M' | bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        for n in 1 2 3; do __bu_tv_read_key 1; printf "%s " "$_TV_KEY"; done
    ')
    assert_equal "$result" "none j none "
}

function test_tv_mouse_reporting_on_off_sequences { #@test
    # Leaving the TUI always turns reporting off, even when toggled off;
    # m toggles it; resume re-enables it only when on
    local f=$BATS_TEST_TMPDIR/out
    local result
    result=$(__tv_in_child '{"a":1}' '
        __bu_tv_rebuild_cache
        _TV_MOUSE=false; __bu_tv_terminal_leave_tui >'"$f"'; printf "leave %q\n" "$(<'"$f"')"
        _TV_MOUSE=true
        __bu_tv_toggle_mouse >'"$f"'; printf "m %s %q\n" "$_TV_MOUSE" "$(<'"$f"')"
        __bu_tv_toggle_mouse >'"$f"'; printf "m %s %q\n" "$_TV_MOUSE" "$(<'"$f"')"
        _TV_RESUME_PENDING=true; __bu_tv_process_signals >'"$f"'
        [[ $(<'"$f"') == *$'"'"'\e[?1000h\e[?1002h\e[?1006h'"'"'* ]] && echo resume-on
        _TV_MOUSE=false; _TV_RESUME_PENDING=true; __bu_tv_process_signals >'"$f"'
        [[ $(<'"$f"') == *$'"'"'\e[?1000h'"'"'* ]] || echo resume-off
        __bu_tv_terminal_restore >/dev/null')
    assert_equal "$result" "leave \$'\\E[?1006l\\E[?1002l\\E[?1000l\\E[?25h\\E[?1049l'
m false \$'\\E[?1006l\\E[?1002l\\E[?1000l'
m true \$'\\E[?1000h\\E[?1002h\\E[?1006h'
resume-on
resume-off"
}

# Snippet prefix for 50 name/version rows in a 20x80 terminal (17 data
# rows), one frame rendered; mouse() dispatches an event and prints state.
# The millisecond clock is __now.
__TV_MOUSE_STUBS='
    __bu_tv_rebuild_cache
    _TV_TERM_ROWS=20; _TV_TERM_COLS=80
    __bu_tv_compute_widths; __bu_tv_clamp_offsets
    __bu_tv_render >/dev/null
    __now=0
    __bu_tv_now_ms() { _TV_NOW_MS=$__now; }
    mouse() { # event x y [button]
        _TV_KEY=mouse _TV_MOUSE_EVENT=$1 _TV_MOUSE_X=$2 _TV_MOUSE_Y=$3 _TV_MOUSE_BUTTON=${4:-0}
        __bu_tv_dispatch
    }
'

function test_tv_scrollbar_layout_and_thumb { #@test
    local result
    result=$(__tv_in_child "$(__tv_rows 50)" "$__TV_MOUSE_STUBS"'
        echo "bar=$_TV_SCROLLBAR_W at $((_TV_TABLE_COLS + 2)) table=$_TV_TABLE_COLS sidebar=$_TV_SIDEBAR_W"
        _TV_SIDEBAR=false; __bu_tv_update_layout
        echo "bar=$_TV_SCROLLBAR_W at $((_TV_TABLE_COLS + 2)) table=$_TV_TABLE_COLS sidebar=$_TV_SIDEBAR_W"
        _TV_SIDEBAR=true
        for off in 0 33 17; do
            _TV_ROW_OFFSET=$off; __bu_tv_scrollbar_thumb
            echo "off=$off height=$_TV_SB_HEIGHT top=$_TV_SB_TOP"
        done
        _TV_ROWS=("${_TV_ROWS[@]:0:17}"); _TV_NUM_ROWS=17
        __bu_tv_rebuild_cache; __bu_tv_update_layout
        echo "bar=$_TV_SCROLLBAR_W table=$_TV_TABLE_COLS sidebar=$_TV_SIDEBAR_W"')
    assert_equal "$result" 'bar=2 at 68 table=66 sidebar=12
bar=2 at 80 table=78 sidebar=0
off=0 height=5 top=0
off=33 height=5 top=12
off=17 height=5 top=6
bar=0 table=68 sidebar=12'
}

function test_tv_mouse_clicks_on_cells_header_and_sidebar { #@test
    # Double-click: a second left press on the same row within 400 ms
    local result
    result=$(__tv_in_child "$(__tv_rows 50)" "$__TV_MOUSE_STUBS"'
        show() { echo "$1: $_TV_MODE r$_TV_CUR_ROW c$_TV_CUR_COL"; }
        __now=1000; mouse press 3 6; show click
        __now=1300; mouse press 3 6; show double
        _TV_MODE=table
        __now=2000; mouse press 3 6; show click
        __now=2700; mouse press 3 6; show "700ms"
        __now=2800; mouse press 3 9; show other-row
        __now=2900; mouse press 3 10 2; show right
        mouse press 10 1; show header
        mouse press 70 3; show sidebar
        mouse press 3 20; show status
        __now=5000; mouse press 30 9; show past-last-col')
    assert_equal "$result" 'click: table r3 c0
double: detail r3 c0
click: table r3 c0
700ms: table r3 c0
other-row: table r6 c0
right: table r6 c0
header: table r6 c1
sidebar: table r6 c0
status: table r6 c0
past-last-col: table r6 c0'
}

function test_tv_mouse_sidebar_scrolls_minimally { #@test
    # 14 columns of 7 in a 70x12 terminal: 6 per screen, 9 data rows
    local result
    result=$(__tv_in_child "$(__tv_wide_row)
$(__tv_wide_row)
$(__tv_wide_row)" '
        __bu_tv_rebuild_cache
        _TV_TERM_ROWS=12; _TV_TERM_COLS=70
        __bu_tv_compute_widths; __bu_tv_clamp_offsets
        press() { _TV_KEY=mouse _TV_MOUSE_EVENT=press _TV_MOUSE_X=65 _TV_MOUSE_Y=$1 _TV_MOUSE_BUTTON=0
            __bu_tv_dispatch; echo "c$_TV_CUR_COL off$_TV_COL_OFFSET"; }
        frame() { __bu_tv_render >/dev/null; echo "window $_TV_SIDEBAR_START..$_TV_SIDEBAR_END"; }
        frame; press 10
        frame; press 11
        frame; press 3')
    assert_equal "$result" 'window 0..8
c7 off2
window 1..8
c8 off3
window 2..9
c1 off1'
}

function test_tv_mouse_scrollbar_page_drag_and_wheel { #@test
    # Bar at column 68, thumb 5 rows; data rows start at screen row 3
    local result
    result=$(__tv_in_child "$(__tv_rows 50)" "$__TV_MOUSE_STUBS"'
        show() { echo "$1: off$_TV_ROW_OFFSET cur$_TV_CUR_ROW $_TV_SB_GRABBED"; }
        mouse press 68 13; show below
        mouse press 68 3; show above
        mouse press 68 5; show thumb
        mouse drag 68 11; show drag
        mouse drag 68 30; show drag-past
        mouse release 68 30; show release
        mouse drag 68 5; show drag-free
        mouse wheel_up 10 10; show wheel-up
        mouse wheel_down 10 10; show wheel-down
        mouse press 67 3; show gap')
    assert_equal "$result" 'below: off17 cur17 false
above: off0 cur0 false
thumb: off0 cur0 true
drag: off17 cur17 true
drag-past: off33 cur33 true
release: off33 cur33 false
drag-free: off33 cur33 false
wheel-up: off30 cur33 false
wheel-down: off33 cur33 false
gap: off33 cur33 false'
}

function test_tv_mouse_in_overlays { #@test
    local rows= r c sep row
    for r in 1 2 3; do
        sep=; row='{'
        for c in {01..20}; do row+="$sep\"c$c\":\"r$r-$c\""; sep=,; done
        rows+="$row}"$'\n'
    done
    local result
    result=$(__tv_in_child "${rows%$'\n'}" '
        __bu_tv_rebuild_cache; _TV_TERM_ROWS=13; __bu_tv_clamp_offsets
        mouse() { _TV_KEY=mouse _TV_MOUSE_EVENT=$1 _TV_MOUSE_X=5 _TV_MOUSE_Y=5 _TV_MOUSE_BUTTON=${2:-0}
            __bu_tv_dispatch; echo "$1/${2:-0}: $_TV_MODE d$_TV_DETAIL_OFFSET h$_TV_HELP_OFFSET"; }
        _TV_KEY=$TV_ENTER; __bu_tv_dispatch
        mouse wheel_down; mouse wheel_down; mouse wheel_up; mouse press 2; mouse press 0
        _TV_KEY=H; __bu_tv_dispatch
        mouse wheel_down; mouse press 0')
    assert_equal "$result" 'wheel_down/0: detail d3 h0
wheel_down/0: detail d6 h0
wheel_up/0: detail d3 h0
press/2: detail d3 h0
press/0: table d3 h0
wheel_down/0: help d3 h3
press/0: table d3 h3'
}

# Snippet prefix for 3 rows of columns a..e in a 20x80 terminal: the
# sidebar is 9 wide at column 72 (names from 75, the cursor entry's ⇤ at 78
# and × at 80) and its list starts on screen row 3.  m() dispatches a
# mouse event and redraws (the event loop's order); st() prints the state.
__TV_SIDEBAR_STUBS='
    __bu_tv_rebuild_cache
    _TV_TERM_ROWS=20; _TV_TERM_COLS=80
    __bu_tv_compute_widths; __bu_tv_clamp_offsets
    __bu_tv_render >/dev/null
    m() { # event x y
        _TV_KEY=mouse _TV_MOUSE_EVENT=$1 _TV_MOUSE_X=$2 _TV_MOUSE_Y=$3 _TV_MOUSE_BUTTON=0
        __bu_tv_dispatch; __bu_tv_render >/dev/null
    }
    drag() { m press 76 "$1"; m drag 76 "$2"; m release 76 "$2"; }
    st() { echo "$1: ${_TV_COLUMNS[*]} f$_TV_FROZEN_N c$_TV_CUR_COL h${#_TV_HIDDEN[@]}"; }
'
__TV_ABCDE='{"a":"1","b":"2","c":"3","d":"4","e":"5"}'

function test_tv_sidebar_buttons_and_hidden_click { #@test
    # ⇤ / × act on the cursor entry only; a click on a hidden entry (press
    # and release, no drag) brings it back with the cursor on it
    local result
    result=$(__tv_in_child "$__TV_ABCDE
$__TV_ABCDE" "$__TV_SIDEBAR_STUBS"'
        echo "sidebar=$_TV_SIDEBAR_W at $((_TV_TABLE_COLS + _TV_SCROLLBAR_W + 1))"
        m press 78 4; st other-entry
        m press 78 4; st freeze
        m press 77 3; st unfreeze
        m press 80 3; st hide
        m press 76 8; st hidden-press
        m release 76 8; st hidden-release')
    assert_equal "$result" 'sidebar=9 at 72
other-entry: a b c d e f0 c1 h0
freeze: b a c d e f1 c0 h0
unfreeze: b a c d e f0 c0 h0
hide: a c d e f0 c0 h1
hidden-press: a c d e f0 c0 h1
hidden-release: b a c d e f0 c0 h0'
}

function test_tv_sidebar_drag_moves_freezes_and_hides { #@test
    # A drop takes the target row's place; the title rows freeze, the
    # divider unfreezes, the Hidden title and blank rows below hide
    local result
    result=$(__tv_in_child "$__TV_ABCDE
$__TV_ABCDE" "$__TV_SIDEBAR_STUBS"'
        drag 7 4; st e-onto-b
        m press 76 6; m drag 76 2; m release 76 1; st c-to-top
        drag 3 4; st c-onto-divider
        drag 4 6; st a-onto-b
        m press 76 7; m release 76 7; st no-drag
        drag 7 12; st d-below
        drag 4 7; st e-onto-title
        drag 3 3; st c-onto-itself
        m press 76 4; m drag 76 6; m drag 76 4; m release 76 4; st back-to-own-row')
    assert_equal "$result" 'e-onto-b: a e b c d f0 c1 h0
c-to-top: c a e b d f1 c0 h0
c-onto-divider: c a e b d f0 c0 h0
a-onto-b: c e b a d f0 c3 h0
no-drag: c e b a d f0 c4 h0
d-below: c e b a f0 c3 h1
e-onto-title: c b a f0 c1 h2
c-onto-itself: c b a f0 c0 h2
back-to-own-row: c b a f0 c1 h2'
}

function test_tv_sidebar_drag_underlines_drop_target { #@test
    # Nothing is underlined until the entry leaves its row; then the row
    # under the pointer is (the title above the list, the blank rows below)
    local result
    result=$(__tv_in_child "$__TV_ABCDE" "$__TV_SIDEBAR_STUBS"'
        u() { __bu_tv_render | sed -E "s/$(printf "\033")\\[4m/<u>/g; s/$(printf "\033")\\[[0-9;?]*[A-Za-z]/|/g" \
            | grep -o "<u>|*[^|]*" | tr "\n" " "; echo "($1)"; }
        m press 76 4; u pressed
        m drag 76 6; u over-d
        m drag 76 1; u over-title
        m drag 76 12; u below
        m release 76 12; u released')
    assert_equal "$result" '(pressed)
<u>| d      (over-d)
<u>Columns (over-title)
<u>        (below)
(released)'
}

function test_tv_sidebar_drag_hidden_back_and_restore_order { #@test
    # A hidden entry dropped on a column row comes back in its place (onto
    # a frozen row: frozen); the saved index of columns hidden after it
    # shifts, so + still restores the rest in place
    local result
    result=$(__tv_in_child "$__TV_ABCDE
$__TV_ABCDE" "$__TV_SIDEBAR_STUBS"'
        _TV_KEY=-; __bu_tv_dispatch_key; _TV_KEY=-; __bu_tv_dispatch_key
        __bu_tv_render >/dev/null; st hid-a-b
        drag 7 4; st a-onto-d
        _TV_KEY=+; __bu_tv_dispatch_key; st plus
        # a frozen, then b hidden from the scrolling block
        _TV_KEY=f; __bu_tv_dispatch_key; _TV_KEY=l; __bu_tv_dispatch_key
        _TV_KEY=-; __bu_tv_dispatch_key; __bu_tv_render >/dev/null; st frozen-hid-b
        drag 9 3; st b-onto-frozen
        __bu_tv_restore_col 7; st bad-index')
    assert_equal "$result" 'hid-a-b: c d e f0 c0 h2
a-onto-d: c a d e f0 c1 h1
plus: b c a d e f0 c2 h0
frozen-hid-b: a c d e f1 c1 h1
b-onto-frozen: b a c d e f2 c0 h0
bad-index: b a c d e f2 c0 h0'
}

function test_tv_status_hint_clicks { #@test
    # A click on a hint presses its key: "a/b" by the half clicked (a on
    # the label), Enter and Esc by name; a click off the hints does nothing
    local result
    result=$(__tv_in_child "$__TV_ABCDE
$__TV_ABCDE" "$__TV_SIDEBAR_STUBS"'
        _TV_STATUS_HINTS="n/N:match Esc:clear /:search Enter:detail"; _TV_STATUS_HINTS_X=11
        for x in 10 11 12 13 15 20 21 31 32 41; do
            __bu_tv_status_hint_key "$x"; printf "%s=%q " "$x" "$_TV_KEY"
        done; echo
        _TV_KEY=-; __bu_tv_dispatch_key; __bu_tv_render >/dev/null; st hidden
        s=$_TV_STATUS; __bu_tv_strip_ansi s
        pre=${s%%+:unhide*}
        m press $((${#pre} + 1)) 20; st clicked-unhide
        _TV_KEY=$TV_ENTER; __bu_tv_dispatch; __bu_tv_render >/dev/null
        s=$_TV_STATUS; __bu_tv_strip_ansi s; pre=${s%%q:back*}
        m press $((${#pre} + 1)) 20; echo "detail q:back -> $_TV_MODE"')
    assert_equal "$result" "10=none 11=n 12=n 13=N 15=n 20=none 21=escape 31=/ 32=/ 41=\$'\\n' 
hidden: b c d e f0 c0 h1
clicked-unhide: a b c d e f0 c1 h0
detail q:back -> table"
}

function test_tv_sidebar_wheel_scrolls_long_list_until_a_key { #@test
    # 14 columns in a 70x12 terminal: 14 list rows (no Hidden title, as
    # nothing is hidden) for 9 data rows.  The
    # wheel over the sidebar scrolls its list (clamped), over the table the
    # rows; a key returns the list to following the viewport
    local result
    result=$(__tv_in_child "$(__tv_wide_row)
$(__tv_wide_row)
$(__tv_wide_row)" '
        __bu_tv_rebuild_cache
        _TV_TERM_ROWS=12; _TV_TERM_COLS=70
        __bu_tv_compute_widths; __bu_tv_clamp_offsets
        __bu_tv_render >/dev/null
        wheel() { _TV_KEY=mouse _TV_MOUSE_EVENT=$1 _TV_MOUSE_X=$2 _TV_MOUSE_Y=5 _TV_MOUSE_BUTTON=0
            __bu_tv_dispatch; __bu_tv_render >/dev/null
            echo "$1@$2: window $_TV_SIDEBAR_START..$_TV_SIDEBAR_END of $_TV_SIDEBAR_NROWS scroll $_TV_SIDEBAR_SCROLL"; }
        wheel wheel_down 65; wheel wheel_down 65; wheel wheel_down 65; wheel wheel_up 65
        _TV_KEY=j; __bu_tv_dispatch; __bu_tv_render >/dev/null
        echo "key: window $_TV_SIDEBAR_START..$_TV_SIDEBAR_END scroll $_TV_SIDEBAR_SCROLL"')
    assert_equal "$result" 'wheel_down@65: window 3..10 of 14 scroll 3
wheel_down@65: window 6..13 of 14 scroll 6
wheel_down@65: window 6..14 of 14 scroll 9
wheel_up@65: window 3..10 of 14 scroll 3
key: window 0..8 scroll -1'
}

# ── Filter ───────────────────────────────────────────────────────────────

function test_tv_filter_view_smart_case { #@test
    local result
    result=$(__tv_in_child "$(__tv_rows 12 3 7 11)" '
        __bu_tv_rebuild_cache
        for q in hit HIT Hit "cmd-1" ""; do
            _TV_FILTER_QUERY=$q; __bu_tv_apply_filter
            echo "[$q] $_TV_NUM_VIEW:" "${_TV_VIEW[@]}"
        done')
    assert_equal "$result" '[hit] 3: 2 6 10
[HIT] 0:
[Hit] 0:
[cmd-1] 3: 0 9 11
[] 12: 0 1 2 3 4 5 6 7 8 9 10 11'
}

# Snippet prefix for the filter prompt: like __TV_PROMPT_STUBS, but each
# render records "prompt|filter|view size|cursor|offset|cursor's data row"
__TV_FILTER_STUBS='
    __tv_keys=(); __tv_ki=0; __tv_frames=()
    __bu_tv_read_key() {
        _TV_KEY=${__tv_keys[__tv_ki]:-EOF}
        __tv_ki=$((__tv_ki + 1))
        if [[ $_TV_KEY == EOF ]]; then _TV_EOF=true; _TV_KEY=q; fi
        return 0
    }
    __tv_state() { __bu_tv_cursor_data
        echo "$_TV_PROMPT_TEXT|$_TV_FILTER_QUERY|$_TV_NUM_VIEW|$_TV_CUR_ROW|$_TV_ROW_OFFSET|$_TV_FOUND_IDX"; }
    __bu_tv_render() { __tv_frames+=("$(__tv_state)"); }
    __tv_report() { printf "%s\n" "${__tv_frames[@]}"; echo "end:$(__tv_state)"; }
    __bu_tv_rebuild_cache
    _TV_TERM_ROWS=13
    _TV_CUR_ROW=11; _TV_ROW_OFFSET=6; __bu_tv_clamp_offsets
'

function test_tv_filter_prompt_keeps_cursor_record { #@test
    # Cursor on cmd-12 (data 11).  "2": 12 rows, cmd-12 is view row 1;
    # "25": cmd-12 is out, the cursor takes the next row (cmd-25);
    # Backspace brings cmd-12 back under the cursor
    local result
    result=$(__tv_in_child "$(__tv_rows 30)" "$__TV_FILTER_STUBS"'
        __tv_keys=(2 5 "$TV_BS" "$TV_ENTER")
        __bu_tv_prompt "&"
        __tv_report
        _TV_KEY=escape; __bu_tv_dispatch_key; echo "esc:$(__tv_state)"')
    assert_equal "$result" '&||30|11|6|11
&2|2|12|1|0|11
&25|25|1|0|0|24
&2|2|12|1|0|11
end:|2|12|1|0|11
esc:||30|11|10|11'
}

function test_tv_filter_prompt_refine_cancel_and_clear { #@test
    # The prompt starts from the current filter; Esc restores it; Ctrl-U
    # then Enter clears it (every row).  "cmd-10" leaves cmd-12 (data 11)
    # out, so the cursor falls back to the last row before the end
    local result
    result=$(__tv_in_child "$(__tv_rows 30)" "$__TV_FILTER_STUBS"'
        __bu_tv_filter_to cmd-1 11 5
        __tv_keys=(0 escape)
        __bu_tv_prompt "&"; __tv_report
        __tv_frames=(); __tv_keys=("$TV_CTRL_U" "$TV_ENTER"); __tv_ki=0
        __bu_tv_prompt "&"; __tv_report')
    assert_equal "$result" '&cmd-1|cmd-1|11|3|0|11
&cmd-10|cmd-10|1|0|0|9
end:|cmd-1|11|3|0|11
&cmd-1|cmd-1|11|3|0|11
&||30|11|8|11
end:||30|11|8|11'
}

function test_tv_filter_with_search_sort_and_status { #@test
    # Search runs over the filtered view; a sort keeps the cursor's record
    # and re-applies the filter in the new order
    local result
    result=$(__tv_in_child "$(__tv_rows 30)" '
        __bu_tv_rebuild_cache; _TV_TERM_ROWS=13; __bu_tv_clamp_offsets
        __bu_tv_filter_to 2 -1 0
        _TV_SEARCH_QUERY=cmd-2; __bu_tv_update_search_matches
        echo "matches=${_TV_MATCHED_ROWS[*]}"
        _TV_KEY=n; __bu_tv_dispatch_key; __bu_tv_cursor_data; echo "n: view $_TV_CUR_ROW data $_TV_FOUND_IDX"
        __bu_tv_render_status; s=$_TV_STATUS; __bu_tv_strip_ansi s; echo "$s"
        _TV_KEY=S; __bu_tv_dispatch_key; __bu_tv_cursor_data
        echo "sorted: view $_TV_CUR_ROW ${_TV_ROWS[_TV_FOUND_IDX]} first ${_TV_ROWS[_TV_VIEW[0]]} n=$_TV_NUM_VIEW"')
    assert_equal "$result" 'matches=0 2 3 4 5 6 7 8 9 10 11
n: view 2 data 19
Row 3/12 | Col name (1/2) | &2 12/30 | /cmd-2 2/11 [name] | n/N:match H:help
sorted: view 9 {"name":"cmd-20","version":"1.0"} first {"name":"cmd-29","version":"1.0"} n=12'
}

# ── Header arrow and NO_COLOR ────────────────────────────────────────────

function test_tv_sorted_header_gets_arrow_room { #@test
    # The sorted column's full width counts " ↑"; a capped header keeps
    # the arrow and truncates the label instead
    local result
    result=$(__tv_in_child '{"abcd":"x","efghijkl":"y"}' '
        __bu_tv_rebuild_cache; echo "${_TV_COL_FULL_WIDTHS[*]}"
        __bu_tv_sort_by_column abcd; echo "${_TV_COL_FULL_WIDTHS[*]}"
        _TV_MAX_WIDTH=4; __bu_tv_sort_by_column efghijkl desc; __bu_tv_clamp_offsets
        __bu_tv_compute_visible_cols; __bu_tv_render_line -1 "" line
        __bu_tv_strip_ansi line; echo "[$line]"')
    assert_equal "$result" '4 8
6 8
[abcd  e… ↓]'
}

function test_tv_no_color_resolution { #@test
    local result
    result=$(__tv_in_child '{"a":1}' '
        show() { __bu_tv_resolve_colors "$1"; printf "%s %q\n" "$BU_RET" "$_TV_HIT_ATTR"; }
        unset NO_COLOR; show ""; show none
        NO_COLOR=1; show ""; show auto; show "a=red"
        NO_COLOR=; show ""')
    assert_equal "$result" "auto \$'\\E[43;30m'
none \$'\\E[43;30m'
none \$'\\E[1;4;7m'
auto \$'\\E[1;4;7m'
a=red \$'\\E[1;4;7m'
auto \$'\\E[43;30m'"
}

# ── Freeze, hide, move ───────────────────────────────────────────────────

function test_tv_freeze_pins_column_while_paging { #@test
    # 14 columns of 7 in a 60-column table area: frozen col01 takes 9,
    # leaving 51 (5 columns) to scroll
    local result
    result=$(__tv_in_child "$(__tv_wide_row)" '
        _TV_TERM_COLS=70; __bu_tv_rebuild_cache; __bu_tv_clamp_offsets
        show() { __bu_tv_compute_visible_cols; echo "$1: cur $_TV_CUR_COL off $_TV_COL_OFFSET vis ${_TV_VIS_COLS[*]}"; }
        _TV_KEY=f; __bu_tv_dispatch_key; show freeze
        __bu_tv_page_cols_right; show right
        __bu_tv_page_cols_right; show right
        __bu_tv_page_cols_left; show left
        __bu_tv_page_cols_left; show left
        __bu_tv_page_cols_left; show left
        _TV_CUR_COL=0; __bu_tv_clamp_offsets; show on-frozen
        __bu_tv_render_status; [[ $_TV_STATUS == *"Col col01 (1/14) frozen"* ]] && echo status-frozen')
    assert_equal "$result" 'freeze: cur 0 off 1 vis 0 1 2 3 4 5
right: cur 6 off 6 vis 0 6 7 8 9 10
right: cur 11 off 9 vis 0 9 10 11 12 13
left: cur 5 off 5 vis 0 5 6 7 8 9
left: cur 1 off 1 vis 0 1 2 3 4 5
left: cur 1 off 1 vis 0 1 2 3 4 5
on-frozen: cur 0 off 1 vis 0 1 2 3 4 5
status-frozen'
}

function test_tv_freeze_moves_columns_and_unfreezes { #@test
    local result
    result=$(__tv_in_child "$(__tv_wide_row)" '
        _TV_TERM_COLS=70; __bu_tv_rebuild_cache; __bu_tv_clamp_offsets
        show() { echo "$1: n=$_TV_FROZEN_N cur=$_TV_CUR_COL ${_TV_COLUMNS[*]:0:4}"; }
        _TV_KEY=f; __bu_tv_dispatch_key; show f
        _TV_CUR_COL=5; _TV_KEY=f; __bu_tv_dispatch_key; show f
        _TV_CUR_COL=0; _TV_KEY=f; __bu_tv_dispatch_key; show unfreeze
        __bu_tv_compute_visible_cols; echo "vis ${_TV_VIS_COLS[*]}"')
    assert_equal "$result" 'f: n=1 cur=0 col01 col02 col03 col04
f: n=2 cur=1 col01 col06 col02 col03
unfreeze: n=1 cur=1 col06 col01 col02 col03
vis 0 1 2 3 4 5'
}

function test_tv_freeze_suspended_without_room { #@test
    # Two 40-wide columns can't share a 50-column screen: the freeze waits
    local x
    x=$(printf 'x%.0s' {1..50})
    local result
    result=$(__tv_in_child '{"a":"'"$x"'","b":"'"$x"'","c":"'"$x"'"}' '
        _TV_TERM_COLS=50; __bu_tv_rebuild_cache; __bu_tv_clamp_offsets
        _TV_KEY=f; __bu_tv_dispatch_key
        _TV_CUR_COL=2; __bu_tv_clamp_offsets; __bu_tv_compute_visible_cols
        echo "n=$_TV_FROZEN_N eff=$_TV_FROZEN_EFF vis ${_TV_VIS_COLS[*]}"
        _TV_TERM_COLS=100; __bu_tv_compute_widths; __bu_tv_clamp_offsets; __bu_tv_compute_visible_cols
        echo "n=$_TV_FROZEN_N eff=$_TV_FROZEN_EFF vis ${_TV_VIS_COLS[*]}"')
    assert_equal "$result" 'n=1 eff=0 vis 2
n=1 eff=1 vis 0 2'
}

function test_tv_hide_restore_and_move_columns { #@test
    local result
    result=$(__tv_in_child '{"a":"1","b":"2","c":"3","d":"4","e":"5"}' '
        __bu_tv_rebuild_cache; __bu_tv_clamp_offsets
        k() { _TV_KEY=$1; __bu_tv_dispatch_key; echo "$1: ${_TV_COLUMNS[*]} cur=$_TV_CUR_COL n=$_TV_FROZEN_N hidden=${#_TV_HIDDEN[@]} cells=${_TV_CELLS[*]}"; }
        _TV_CUR_COL=2; k -; k -
        k +
        k "<"; k ">"; k ">"
        _TV_CUR_COL=0; k f; k ">"
        _TV_CUR_COL=1; k "<"
        _TV_CUR_COL=0; k -; k +
        # Down to one column: it stops being frozen and cannot be hidden
        for i in 1 2 3 4; do _TV_KEY=-; __bu_tv_dispatch_key; done; k -')
    assert_equal "$result" '-: a b d e cur=2 n=0 hidden=1 cells=1 2 4 5
-: a b e cur=2 n=0 hidden=2 cells=1 2 5
+: a b c d e cur=4 n=0 hidden=0 cells=1 2 3 4 5
<: a b c e d cur=3 n=0 hidden=0 cells=1 2 3 5 4
>: a b c d e cur=4 n=0 hidden=0 cells=1 2 3 4 5
>: a b c d e cur=4 n=0 hidden=0 cells=1 2 3 4 5
f: a b c d e cur=0 n=1 hidden=0 cells=1 2 3 4 5
>: a b c d e cur=0 n=1 hidden=0 cells=1 2 3 4 5
<: a b c d e cur=1 n=1 hidden=0 cells=1 2 3 4 5
-: b c d e cur=0 n=0 hidden=1 cells=2 3 4 5
+: a b c d e cur=1 n=1 hidden=0 cells=1 2 3 4 5
-: a cur=0 n=0 hidden=4 cells=1'
}

function test_tv_hidden_column_leaves_search { #@test
    local result
    result=$(__tv_in_child '{"a":"x","b":"needle"}
{"a":"needle","b":"y"}' '
        __bu_tv_rebuild_cache; __bu_tv_clamp_offsets
        _TV_SEARCH_QUERY=needle; __bu_tv_update_search_matches
        echo "rows=${_TV_MATCHED_ROWS[*]} cols=${_TV_MATCHED_COLS[*]}"
        _TV_CUR_COL=1; _TV_KEY=-; __bu_tv_dispatch_key
        echo "rows=${_TV_MATCHED_ROWS[*]} cols=${_TV_MATCHED_COLS[*]}"')
    assert_equal "$result" 'rows=0 1 cols=1 0
rows=1 cols=0'
}

# ── Sort ─────────────────────────────────────────────────────────────────

function test_tv_sort_orders_raw_values { #@test
    # Without -s, sort_by ran per object and emptied the table
    local result
    result=$(__tv_in_child '{"k":2,"s":"b"}
{"k":10,"s":"c"}
{"k":null,"s":"n"}
{"k":1,"s":"a"}' \
        '__bu_tv_rebuild_cache
        __bu_tv_sort_by_column k
        echo "rc=$? rows=${#_TV_ROWS[@]} cells=${#_TV_CELLS[@]} $_TV_SORT_DIR perm=${_TV_SORT_PERM[*]} cur=$_TV_CUR_ROW"
        printf "%s|" "${_TV_CELLS[@]}"; echo
        __bu_tv_sort_by_column k
        echo "rc=$? rows=${#_TV_ROWS[@]} cells=${#_TV_CELLS[@]} $_TV_SORT_DIR perm=${_TV_SORT_PERM[*]} cur=$_TV_CUR_ROW"
        printf "%s|" "${_TV_CELLS[@]}"')
    # The cursor follows record 0 ({"k":2}) through both sorts
    assert_equal "$result" $'rc=0 rows=4 cells=8 asc perm=2 3 0 1 cur=2\n\x02|n|1|a|2|b|10|c|\nrc=0 rows=4 cells=8 desc perm=3 2 1 0 cur=1\n10|c|2|b|1|a|\x02|n|'
}

function test_tv_sort_bad_jq_output_leaves_rows_untouched { #@test
    local result
    result=$(__tv_in_child '{"k":2}
{"k":1}' \
        '__bu_tv_rebuild_cache
        before=$(printf "%s|" "${_TV_ROWS[@]}" "${_TV_CELLS[@]}" "${_TV_COL_WIDTHS[@]}")
        fake_jq() { echo one; }
        BU_OUT_JQ=fake_jq
        __bu_tv_sort_by_column k 2>/dev/null; rc=$?
        after=$(printf "%s|" "${_TV_ROWS[@]}" "${_TV_CELLS[@]}" "${_TV_COL_WIDTHS[@]}")
        [[ "$before" == "$after" ]] && same=same || same=changed
        echo "rc=$rc $same sort=[$_TV_SORT_COL]"')
    assert_equal "$result" 'rc=1 same sort=[]'
}

function test_tv_sort_cache_failure_restores_rows_and_cursor { #@test
    # jq sorts fine, then the cache rebuild of the sorted rows fails: rows,
    # cache, cursor and sort state all come back
    local result
    result=$(__tv_in_child '{"k":3}
{"k":1}
{"k":2}' \
        '__bu_tv_rebuild_cache; __bu_tv_clamp_offsets
        _TV_CUR_ROW=1
        before=$(printf "%s|" "${_TV_ROWS[@]}" "${_TV_CELLS[@]}" "${_TV_COL_WIDTHS[@]}")
        # jq runs in subshells (pipelines): count calls in a file
        real_jq=$BU_OUT_JQ; calls='"$BATS_TEST_TMPDIR"'/jq_calls; echo 0 >"$calls"
        flaky_jq() {
            local n; n=$(($(<"$calls") + 1)); echo "$n" >"$calls"
            if (( n == 2 )); then echo garbage; return 0; fi
            "$real_jq" "$@"
        }
        BU_OUT_JQ=flaky_jq
        _TV_KEY=s; __bu_tv_dispatch_key 2>/dev/null
        after=$(printf "%s|" "${_TV_ROWS[@]}" "${_TV_CELLS[@]}" "${_TV_COL_WIDTHS[@]}")
        [[ "$before" == "$after" ]] && same=same || same=changed
        echo "calls=$(<"$calls") $same cur=$_TV_CUR_ROW sort=[$_TV_SORT_COL$_TV_SORT_DIR]"')
    assert_equal "$result" 'calls=3 same cur=1 sort=[]'
}

# ── Entry validation ─────────────────────────────────────────────────────

function test_tv_enter_rejects_bad_max_width { #@test
    # "08" must not reach an integer variable (bad octal aborts the shell).
    # Valid widths run on empty input, which returns before the tty setup.
    local result w
    for w in 08 0 abc -3; do
        result=$(bash -c '
            source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
            source "'"$DIR"'/../lib/core/bu_core_tv.sh"
            echo "{\"a\":1}" | bu_tv_enter "" none true "$1" 2>&1 >/dev/null; echo "rc=$? max=$_TV_MAX_WIDTH"
        ' _ "$w")
        assert_equal "${result##*$'\n'}" 'rc=1 max=40'
        [[ "$result" == *"max width must be a positive integer, got [$w]"* ]]
    done
    for w in 25 ""; do
        result=$(bash -c '
            source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
            source "'"$DIR"'/../lib/core/bu_core_tv.sh"
            bu_tv_enter "" none true "$1" </dev/null >/dev/null 2>&1; echo "rc=$? max=$_TV_MAX_WIDTH"
        ' _ "$w")
        assert_equal "$result" "rc=0 max=${w:-40}"
    done
}

# ===========================================================================
# Performance guards (real timer)
# ===========================================================================

# Child-bash prelude: __tv_now_ns prints a nanosecond timestamp
__TV_TIMER='
    __tv_now_ns() {
        local t
        t=$(date +%s%N 2>/dev/null)
        if [[ $t =~ ^[0-9]+$ ]]; then echo "$t"
        elif [[ -n ${EPOCHREALTIME:-} ]]; then echo "${EPOCHREALTIME/[.,]/}000"
        else gdate +%s%N
        fi
    }
'

function test_tv_frame_perf_500x6_under_100ms { #@test
    local ms
    ms=$(bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        '"$__TV_TIMER"'
        for i in {1..500}; do
            _TV_ROWS+=("{\"name\":\"cmd-$i\",\"verb\":\"get\",\"noun\":\"item-$i\",\"namespace\":\"bu\",\"type\":\"source\",\"extra\":\"val-$i\"}")
        done
        _TV_NUM_ROWS=${#_TV_ROWS[@]}
        _TV_TERM_ROWS=46
        _TV_TERM_COLS=120
        __bu_tv_extract_columns ""
        __bu_tv_rebuild_cache
        __bu_tv_build_colors auto
        _TV_CUR_ROW=250
        __bu_tv_clamp_offsets
        __bu_tv_render >/dev/null   # warm-up
        start=$(__tv_now_ns)
        for f in {1..5}; do __bu_tv_render >/dev/null; done
        end=$(__tv_now_ns)
        echo $(( (end - start) / 5000000 ))
    ')
    echo "frame time: ${ms}ms (limit 100ms)"
    (( ms < 100 ))
}

function test_tv_first_frame_2000x6_under_1s { #@test
    # Startup up to the first frame, minus the tty setup: read, extract
    # columns, cache pass, colours, clamp, render
    local rows=$BATS_TEST_TMPDIR/rows2000.jsonl
    awk 'BEGIN { for (i = 1; i <= 2000; i++)
        printf "{\"name\":\"cmd-%d\",\"verb\":\"get\",\"noun\":\"item-%d\",\"namespace\":\"bu\",\"type\":\"source\",\"extra\":\"val-%d\"}\n", i, i, i }' > "$rows"
    local ms
    ms=$(bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        '"$__TV_TIMER"'
        _TV_TERM_ROWS=46
        _TV_TERM_COLS=120
        start=$(__tv_now_ns)
        __bu_tv_read_stdin <"$1"
        __bu_tv_extract_columns ""
        __bu_tv_rebuild_cache
        __bu_tv_build_colors auto
        __bu_tv_clamp_offsets
        __bu_tv_render >/dev/null
        end=$(__tv_now_ns)
        echo "$(( (end - start) / 1000000 )) $_TV_NUM_ROWS"
    ' _ "$rows")
    echo "first frame: ${ms% *}ms for ${ms#* } rows (limit 1000ms)"
    [[ "${ms#* }" == 2000 ]]
    (( ${ms% *} < 1000 ))
}

# ===========================================================================
# Interactive: driven through a real pty via script(1)
# ===========================================================================

# ```md
# Run `bu view-table < rows` in a pty under script(1), feeding the keys
# produced by a callback on its stdin.
#
# Params:
# - $1: JSONL rows file
# - $2: capture file
# - $3: function that prints the keys (with its own pacing)
# ```
function __tv_script_run {
    local -r rows_file=$1 cap=$2 feeder=$3
    # util-linux script takes the command via -c; BSD/macOS script has no -c
    # and takes it as trailing arguments after the capture file
    local -r inner="source \"$DIR\"/../activate >/dev/null 2>&1 && bu view-table < \"$rows_file\""
    local -a script_cmd=()
    if script -q -c true /dev/null >/dev/null 2>&1; then
        script_cmd=(script -q -c "bash -c '$inner'" "$cap")
    else
        script_cmd=(script -q "$cap" bash -c "$inner")
    fi
    # Let the entrypoint load before feeding keys: keys typed before the
    # viewer owns the tty are swallowed by the intermediate shell, and
    # activation time varies wildly across hosts (CI, network
    # filesystems).  A pipe can't observe the frame, so be generous.
    { sleep 8; "$feeder"; } | timeout 40 "${script_cmd[@]}" >/dev/null
}

function test_tv_interactive_scroll_tracks_keys { #@test
    command -v script >/dev/null || skip "script(1) not available"
    local rows_file=$BATS_TEST_TMPDIR/rows.jsonl cap=$BATS_TEST_TMPDIR/cap.txt
    __tv_rows 50 > "$rows_file"
    __feed() {
        local i
        for i in {1..10}; do printf 'j'; sleep 0.05; done
        sleep 0.5
        printf 'q'
    }
    __tv_script_run "$rows_file" "$cap" __feed
    # After 10x j the cursor is on row 11
    grep -qF 'Row 11/50' "$cap"
}

function test_tv_interactive_search_detail_and_quit { #@test
    command -v script >/dev/null || skip "script(1) not available"
    local rows_file=$BATS_TEST_TMPDIR/rows.jsonl cap=$BATS_TEST_TMPDIR/cap.txt
    local i
    for i in {1..50}; do
        if (( i % 10 == 0 )); then
            printf '{"name":"alpha-%s","version":"1.0"}\n' "$i"
        else
            printf '{"name":"cmd-%s","version":"1.0"}\n' "$i"
        fi
    done > "$rows_file"
    __feed() {
        local k
        for k in / a l p h a; do printf '%s' "$k"; sleep 0.2; done
        printf '\r'; sleep 0.5
        printf 'n'; sleep 0.5
        printf '\r'; sleep 0.5
        printf 'q'; sleep 0.5
        printf 'q'
    }
    __tv_script_run "$rows_file" "$cap" __feed
    grep -qF '/alpha 2/5 [name]' "$cap" || { cat -v "$cap" | tail -c 2000; return 1; }
    grep -qF 'Record 20/50' "$cap"
    grep -qF $'\e[?1049l' "$cap"
    # Mouse reporting on while the TUI is up, off when it leaves
    grep -qF $'\e[?1000h\e[?1002h\e[?1006h' "$cap"
    grep -qF $'\e[?1006l\e[?1002l\e[?1000l\e[?25h\e[?1049l' "$cap"
}

# ===========================================================================
# Key reader: exit-code semantics (EOF vs Enter vs trapped signal)
# ===========================================================================

function __tv_read_key_in_child { # stdin already redirected by caller
    bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        __bu_tv_read_key 1
        printf "%s" "$_TV_KEY"
    '
}

function test_tv_read_key_eof_maps_to_quit { #@test
    local result
    result=$(bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        __bu_tv_read_key 1
        printf "%s %s" "$_TV_KEY" "$_TV_EOF"
    ' </dev/null)
    assert_equal "$result" "q true"
}

function test_tv_read_key_enter_maps_to_newline { #@test
    # read -n1 consumes the newline delimiter: rc=0, empty var -> $'\x0a'
    local result
    result=$(printf '\n' | __tv_read_key_in_child | od -An -tx1 | tr -d ' \n')
    assert_equal "$result" "0a"
}

function test_tv_read_key_cr_maps_to_enter { #@test
    # A tty left in raw mode (no icrnl) delivers CR for Enter
    local result
    result=$(printf '\r' | __tv_read_key_in_child | od -An -tx1 | tr -d ' \n')
    assert_equal "$result" "0a"
}

function test_tv_read_key_regular_key { #@test
    local result
    result=$(printf 'j' | __tv_read_key_in_child)
    assert_equal "$result" "j"
}

function test_tv_read_key_arrow_down { #@test
    local result
    result=$(printf '\e[B' | __tv_read_key_in_child)
    assert_equal "$result" "down"
}

function test_tv_read_key_f1_both_sequences { #@test
    local result
    result=$(printf '\eOP' | __tv_read_key_in_child)
    assert_equal "$result" "f1"
    result=$(printf '\e[11~' | __tv_read_key_in_child)
    assert_equal "$result" "f1"
}

function test_tv_read_key_modified_arrows { #@test
    local seq result
    local -a seqs=('\e[1;2C' '\e[1;5D' '\e[1;2A' '\e[1;6B' '\e[1;3C' '\e[1;2H')
    local -a want=(shift_right shift_left shift_up shift_down right home)
    local -i i
    for i in "${!seqs[@]}"; do
        result=$(printf "${seqs[i]}" | __tv_read_key_in_child)
        assert_equal "$result" "${want[i]}"
    done
}

function test_tv_read_key_modifier_consumes_final_byte { #@test
    # The final byte must not be left behind to dispatch as a stray key,
    # even when the sequence maps to nothing
    local result
    result=$(printf '\e[1;3Cj\e[1;5Zk' | bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        for n in 1 2 3 4; do __bu_tv_read_key 1; printf "%s " "$_TV_KEY"; done
    ')
    assert_equal "$result" "right j none k "
}

function test_tv_read_key_trapped_signal_returns_none { #@test
    # A trap that set a signal flag must end the blocking read with the
    # no-op sentinel "none", NOT "q".  The stub plays the trap (sets the
    # flag) and the interrupted read (rc>128); live signals are covered by
    # the tmux resize and suspend tests.
    local result
    result=$(bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        read() { _TV_RESIZE_PENDING=true; return 142; }
        __bu_tv_read_key 1
        printf "%s" "$_TV_KEY"
    ')
    assert_equal "$result" "none"
}

function test_tv_read_key_poll_timeout_keeps_waiting { #@test
    # A poll slice that times out with no signal flag set must read again,
    # not return "none" (that would render every slice while idle)
    local result
    result=$(bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        declare -i n=0
        read() { n+=1; (( n < 3 )) && return 142; _TV_KEY=j; return 0; }
        __bu_tv_read_key 1
        printf "%s %s" "$_TV_KEY" "$n"
    ')
    assert_equal "$result" "j 3"
}

# ===========================================================================
# Job control: driven through tmux
# ===========================================================================

# ```md
# Poll a tmux pane until its capture matches a pattern (and, if given, no
# longer matches a second one), or tries run out.  Fixed sleeps lose on
# loaded hosts; callers still assert on `pane` afterwards, so a timeout
# surfaces as the original assertion failure.
#
# Params:
# - $1: tmux socket
# - $2: target pane
# - $3: grep -E pattern to wait for
# - $4: max tries at 0.5s each (default 20)
# - $5: grep -E pattern that must be absent (optional)
#
# Returns:
# - pane: last captured frame (caller's local, via dynamic scope)
# ```
function __tv_wait_pane {
    local -r sock=$1 target=$2 pattern=$3 absent=${5:-}
    local -r -i tries=${4:-20}
    local -i _w
    for (( _w = 0; _w < tries; _w++ )); do
        pane=$(tmux -L "$sock" capture-pane -t "$target" -p)
        if grep -qE "$pattern" <<<"$pane"; then
            [[ -z "$absent" ]] && break
            grep -qE "$absent" <<<"$pane" || break
        fi
        sleep 0.5
    done
    return 0
}

function __tv_tmux_setup { # $1=socket $2=session
    local rows=$BATS_TEST_TMPDIR/rows.$2.jsonl
    local i
    local pane
    for i in {1..50}; do printf '{"name":"cmd-%s","version":"1.0"}\n' "$i"; done > "$rows"
    tmux -L "$1" new-session -d -s "$2" -x 100 -y 30 "bash --norc"
    tmux -L "$1" send-keys -t "$2" "source \"$DIR\"/../activate >/dev/null 2>&1; bu view-table < \"$rows\"" Enter
    # Activation time varies wildly across hosts: wait (up to 60s) for the
    # TUI status line before anyone sends keys.
    __tv_wait_pane "$1" "$2" 'Row [0-9]+/' 120
    printf '%s' "$rows"
}

function test_tv_tmux_suspend_resume_cycle { #@test
    command -v tmux >/dev/null || skip "tmux not available"

    local sock="tvsus$$"
    __tv_tmux_setup "$sock" tvsus >/dev/null

    local pane
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'Row 1/' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # Move down 3 (coalesced into one render)
    tmux -L "$sock" send-keys -t tvsus jjj
    __tv_wait_pane "$sock" tvsus 'Row 4/'
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'Row 4/' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # Ctrl-Z: job reports Stopped, pane shows the normal shell (not the TUI)
    tmux -L "$sock" send-keys -t tvsus C-z
    # The shell prints its Stopped notice at its own pace under load
    __tv_wait_pane "$sock" tvsus 'Stopped'
    if grep -q 'Row 4/' <<<"$pane"; then
        echo "TUI still on screen after C-z:"; echo "$pane"
        tmux -L "$sock" kill-server; return 1
    fi
    grep -q 'Stopped' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # fg: the frame repaints at the same cursor
    tmux -L "$sock" send-keys -t tvsus "fg" Enter
    __tv_wait_pane "$sock" tvsus 'Row 4/'
    grep -q 'Row 4/' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # Moving still works after resume
    tmux -L "$sock" send-keys -t tvsus j
    __tv_wait_pane "$sock" tvsus 'Row 5/'
    grep -q 'Row 5/' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # A signal delivered during the blocking read must not exit the viewer
    pkill -WINCH -f 'bu-view-table.sh'
    sleep 0.4
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'Row 5/' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # q returns the prompt with rc 0
    tmux -L "$sock" send-keys -t tvsus q
    # Wait for the viewer to release the screen; keys sent earlier would be
    # read by the TUI instead of the shell
    local -i _w
    for (( _w = 0; _w < 20; _w++ )); do
        pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
        grep -qE 'Row [0-9]+/' <<<"$pane" || break
        sleep 0.5
    done
    tmux -L "$sock" send-keys -t tvsus "echo VIEWER_RC=\$?" Enter
    __tv_wait_pane "$sock" tvsus 'VIEWER_RC=[0-9]'
    grep -q 'VIEWER_RC=0' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    tmux -L "$sock" kill-server
}

function test_tv_tmux_uses_real_window_size { #@test
    # tput inside $(...) 2>/dev/null sees no terminal and reports the
    # terminfo default 80x24; the viewer must ask the tty.  50 rows in a
    # 30-line pane -> 27 data rows (cmd-1..cmd-27); 20 lines -> 17.  The
    # size check waits at most 10s, so a redraw deferred to the next key
    # fails here.
    command -v tmux >/dev/null || skip "tmux not available"

    local sock="tvsize$$"
    local pane
    __tv_tmux_setup "$sock" tvsize >/dev/null
    pane=$(tmux -L "$sock" capture-pane -t tvsize -p)
    grep -q 'Row 1/50' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }
    grep -qE '^cmd-27 ' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }
    if grep -qE '^cmd-28 ' <<<"$pane"; then echo "$pane"; tmux -L "$sock" kill-server; return 1; fi

    # SIGWINCH path: the resize alone must redraw at the new size, with no
    # keypress (a single blocking read would defer the trap until one).
    # The status row only reappears (at row 20) after the redraw.
    tmux -L "$sock" resize-window -t tvsize -x 100 -y 20
    __tv_wait_pane "$sock" tvsize 'Row 1/50' 20 '^cmd-18 '
    grep -q 'Row 1/50' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }
    grep -qE '^cmd-17 ' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }
    if grep -qE '^cmd-18 ' <<<"$pane"; then echo "$pane"; tmux -L "$sock" kill-server; return 1; fi

    # And grow back
    tmux -L "$sock" resize-window -t tvsize -x 100 -y 30
    __tv_wait_pane "$sock" tvsize '^cmd-27 '
    grep -qE '^cmd-27 ' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }
    grep -q 'Row 1/50' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    tmux -L "$sock" send-keys -t tvsize q
    tmux -L "$sock" kill-server
}

function test_tv_tmux_ctrl_c_restores_terminal { #@test
    # SIGINT only sets _TV_QUIT; the event loop must still exit with rc 0
    # and hand back a cooked, echoing terminal
    command -v tmux >/dev/null || skip "tmux not available"

    local sock="tvint$$"
    local pane
    __tv_tmux_setup "$sock" tvint >/dev/null

    tmux -L "$sock" send-keys -t tvint C-c
    local -i _w
    for (( _w = 0; _w < 20; _w++ )); do
        pane=$(tmux -L "$sock" capture-pane -t tvint -p)
        grep -qE 'Row [0-9]+/' <<<"$pane" || break
        sleep 0.5
    done
    tmux -L "$sock" send-keys -t tvint 'echo VIEWER_RC=$?; stty -a | grep -oE "[-]?(icanon|echo) " | tr -d "\n"; echo' Enter
    __tv_wait_pane "$sock" tvint 'VIEWER_RC=[0-9]'
    grep -q 'VIEWER_RC=0' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }
    grep -qE '^icanon echo *$' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    tmux -L "$sock" kill-server
}

function test_tv_tmux_background_refusal { #@test
    command -v tmux >/dev/null || skip "tmux not available"

    local sock="tvbg$$"
    local rows=$BATS_TEST_TMPDIR/rows.bg.jsonl
    local i
    for i in {1..50}; do printf '{"name":"cmd-%s","version":"1.0"}\n' "$i"; done > "$rows"

    tmux -L "$sock" new-session -d -s tvbg -x 100 -y 30 "bash --norc"
    tmux -L "$sock" send-keys -t tvbg "source \"$DIR\"/../activate >/dev/null 2>&1; bu view-table < \"$rows\" &" Enter

    # Backgrounded pipeline: not the tty's foreground group -> loud refusal,
    # NOT a silent kernel stop of the pipeline.  Activation time varies
    # wildly across hosts, so wait (up to 60s) for the refusal.
    local pane
    __tv_wait_pane "$sock" tvbg 'foreground group|Row [0-9]+/' 120
    grep -q "foreground group" <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }
    if grep -q 'Row 1/' <<<"$pane"; then
        echo "TUI started despite background process group:"; echo "$pane"
        tmux -L "$sock" kill-server; return 1
    fi

    tmux -L "$sock" kill-server
}
