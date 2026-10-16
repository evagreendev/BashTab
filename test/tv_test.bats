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
#              regex prompt detail help nosidebar sorted overflow paged; do
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
    # Cursor row reversed end to end (padding inside the attribute), cursor
    # column header bold+underline, other headers bold, plain rows trimmed
    __tv_check_golden plain \
        $'\e[1;1H\e[1;4mname\e[0m' \
        $'\e[1mverb\e[0m' \
        $'\e[3;1H\e[7mget-command              get                  \e[0m\e[K' \
        $'\e[4;1Hformat-table             format\e[K' \
        $'\e[20;1H\e[2mRow 1/5 | Col name (1/5) | H:help\e[0m\e[K\e[?25l'
}

function test_tv_frame_scrolled_matches_golden { #@test
    # Cursor on the last row/column: the viewport scrolled the minimum
    __tv_check_golden scrolled \
        $'\e[1;1H\e[1mverb\e[0m' \
        $'\e[1;4mtype\e[0m' \
        $'\e[3;1Hformat ' \
        $'\e[6;1H\e[7mselect' \
        'Row 5/5 | Col type (5/5)'
}

function test_tv_frame_cursor_matches_golden { #@test
    __tv_check_golden cursor \
        $'\e[1;4mverb\e[0m' \
        $'\e[5;1H\e[7mconvert-from-asciitable  convert-from         \e[0m\e[K' \
        'Row 3/5 | Col verb (2/5)'
}

function test_tv_frame_search_matches_golden { #@test
    # A hit inside the reversed cursor row re-applies the row attribute
    __tv_check_golden search \
        $'\e[43;30mget\e[0m\e[7m-command' \
        $'\e[43;30mget\e[0m\e[7m ' \
        '/get 1/1 [name]'
}

function test_tv_frame_search_truncated_matches_golden { #@test
    # Hits hidden by truncation highlight the ellipsis, in and out of the
    # cursor row
    __tv_check_golden search_truncated \
        $'format-\e[43;30mta\e[0m\e[7m\e[43;30m…\e[0m\e[7m' \
        $'convert-f\e[43;30m…\e[0m  ' \
        $'ascii\e[43;30mtable\e[0m' \
        '/table 1/2 [name]'
}

function test_tv_frame_search_expanded_matches_golden { #@test
    __tv_check_golden search_expanded \
        $'format-\e[43;30mtable\e[0m\e[7m' \
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
        $'\e[7m\e[43;30mge\e[0m\e[7mt-command'
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
        $'\e[15;1H          \e[43;30mline\e[0m2\e[K'
}

function test_tv_frame_help_matches_golden { #@test
    __tv_check_golden help \
        $'\e[1;1H\e[1mKeys\e[0m\e[K' \
        '0 $ Home End' \
        'Shift-→ Shift-←    page columns right / left' \
        'Lines 1-17/'
}

function test_tv_frame_nosidebar_matches_golden { #@test
    __tv_check_golden nosidebar $'\e[3;1H\e[7mget-command'
    if grep -qF 'Columns' "$BATS_TEST_TMPDIR/nosidebar.actual"; then
        echo "sidebar drawn while hidden"
        return 1
    fi
}

function test_tv_frame_sorted_sidebar_matches_golden { #@test
    # The cursor followed get-command through the sort; the sidebar shows
    # the sort arrow and ▸ on the cursor column
    __tv_check_golden sorted \
        $'\e[5;1H\e[7mget ' \
        $'\e[7m▸namespace' \
        'Sorted: verb ↓'
}

function test_tv_frame_sidebar_overflow_matches_golden { #@test
    # More columns than data rows: the list scrolls to the viewport with
    # "↑ N more" / "↓ N more" rows
    __tv_check_golden overflow \
        $'\e[1;1H\e[1mcol06\e[0m' \
        $'\e[7m▸col11' \
        '↑ 4 more' \
        '↓ 3 more'
}

function test_tv_frame_paged_matches_golden { #@test
    # One page right from column 0: col07 is the new left edge and cursor
    __tv_check_golden paged \
        $'\e[1;1H\e[1;4mcol07\e[0m' \
        'Col col07 (7/14)'
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
    assert_equal "$result" 'rc=0
9|1||x|2|b\tc|||||
4 4 4'
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
    # `. // ""` treats false like null; only null may be blank
    local result
    result=$(__tv_in_child '{"b":false,"t":true,"z":0,"n":null,"s":""}' \
        '__bu_tv_rebuild_cache; printf "%s|" "${_TV_CELLS[@]}"')
    assert_equal "$result" 'false|true|0|||'
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
    result=$(__tv_in_child '{"abcdefghij":1,"b":2}' \
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
        for w in 120 60 20; do
            _TV_TERM_COLS=$w; __bu_tv_render_status
            s=$_TV_STATUS; __bu_tv_strip_ansi s; echo "[$s]"
        done')
    assert_equal "$result" '[Row 1/5 | Col name (1/2) | q:quit /:search s:sort w:wide Enter:detail H:help]
[Row 1/5 | Col name (1/2) | H:help]
[Row 1/5 | Col name ]'
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
<>
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
    assert_equal "$result" 'rc=0 rows=4 cells=8 asc perm=2 3 0 1 cur=2
|n|1|a|2|b|10|c|
rc=0 rows=4 cells=8 desc perm=3 2 1 0 cur=1
10|c|2|b|1|a||n|'
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
