#!/usr/bin/env bats

# Tests for lib/core/bu_core_tv.sh (bu view-table — interactive table viewer).
#
# Golden-frame tests compare __bu_tv_render_frame output byte-for-byte
# against fixtures captured in test/fixtures/.  Both the fixtures and the
# tests are produced by the same driver (test/tv_render_state.sh), so the
# states can't drift.  Regenerate fixtures after intentional renderer
# changes with:
#
#     for s in plain scrolled search regex; do
#         bash test/tv_render_state.sh "$s" > test/fixtures/tv_frame_$s.expected
#     done
#
# The perf guard times a frame inside a child `bash -c`: bats' DEBUG trap
# inflates pure-bash loops ~100x, which would make the measurement useless.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # Fixtures and widths are UTF-8; don't depend on the caller's locale
    export LC_ALL=C.UTF-8
}

# ===========================================================================
# Golden frames (byte-identity)
# ===========================================================================

function __tv_check_golden { # state
    local state=$1
    bash "$DIR/tv_render_state.sh" "$state" > "$BATS_TEST_TMPDIR/$state.actual"
    cmp "$BATS_TEST_TMPDIR/$state.actual" "$DIR/fixtures/tv_frame_$state.expected"
}

function test_tv_frame_plain_matches_golden { #@test
    __tv_check_golden plain
}

function test_tv_frame_scrolled_matches_golden { #@test
    __tv_check_golden scrolled
}

function test_tv_frame_search_matches_golden { #@test
    __tv_check_golden search
}

function test_tv_frame_regex_query_matches_golden { #@test
    # Query with regex metachars ("a.e") must match literally
    __tv_check_golden regex
}

function test_tv_frame_independent_of_term { #@test
    # tput sgr0 is \e(B\e[m under xterm, \e[m\017 under screen and empty
    # under dumb; the frame must use raw CSI only.  Each run re-sources the
    # entrypoint, so the tput values are recomputed under that TERM.
    local t
    for t in xterm-256color screen-256color dumb; do
        TERM=$t bash "$DIR/tv_render_state.sh" plain > "$BATS_TEST_TMPDIR/plain.$t"
    done
    cmp "$BATS_TEST_TMPDIR/plain.xterm-256color" "$BATS_TEST_TMPDIR/plain.screen-256color"
    cmp "$BATS_TEST_TMPDIR/plain.xterm-256color" "$BATS_TEST_TMPDIR/plain.dumb"
    cmp "$BATS_TEST_TMPDIR/plain.xterm-256color" "$DIR/fixtures/tv_frame_plain.expected"
}

# ===========================================================================
# Cell cache and sort (run in a child bash: see the perf guard note)
# ===========================================================================

# ```md
# Run a snippet in a child bash with the viewer loaded and `rows` (JSONL,
# one record per line) loaded into _TV_ROWS with columns extracted.
#
# Params:
# - $1: JSONL rows
# - $2: bash snippet to run afterwards
# ```
function __tv_in_child {
    bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        mapfile -t _TV_ROWS <<<"$1"
        _TV_NUM_ROWS=${#_TV_ROWS[@]}
        __bu_tv_extract_columns ""
        eval "$2"
    ' _ "$1" "$2"
}

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

function test_tv_cache_count_mismatch_refuses { #@test
    # A shifted parse must clear the cache and fail rather than render
    local result
    result=$(__tv_in_child '{"a":1,"b":2}
{"a":3,"b":4}' \
        'fake_jq() { printf "4 4\n1\x012\x01.\n"; }
        BU_OUT_JQ=fake_jq
        __bu_tv_rebuild_cache 2>/dev/null; echo "rc=$? cells=${#_TV_CELLS[@]} widths=${#_TV_COL_WIDTHS[@]}"')
    assert_equal "$result" 'rc=1 cells=0 widths=0'
}

function test_tv_truncated_header_not_over_padded { #@test
    # The ellipsis occupies the last cell of the column
    local result
    result=$(__tv_in_child '{"abcdefghij":1,"b":2}' \
        '__bu_tv_rebuild_cache
        _TV_COL_WIDTHS=(6 4)
        __bu_tv_compute_visible_cols
        __bu_tv_render_line -1 false line
        __bu_tv_strip_ansi line
        printf "[%s]" "$line"')
    assert_equal "$result" '[abcde…  b]'
}

# ```md
# Run bu_tv_enter on empty input in a scrubbed child (env -i), then report
# the locale it left behind and the length of a 5-character non-ASCII word.
#
# Params:
# - $@: extra NAME=VALUE environment for the child
# ```
function __tv_locale_in_child {
    env -i HOME="$HOME" PATH="$PATH" "$@" bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        bu_tv_enter "" "" </dev/null >/dev/null 2>&1
        x=h'$'\xc3\xa9''llo
        echo "LC_CTYPE=${LC_CTYPE-unset} LC_ALL=${LC_ALL-unset} LANG=${LANG-unset} len=${#x}"
    '
}

function test_tv_locale_forced_to_utf8_without_lang { #@test
    # Bash counts bytes under the POSIX locale; jq counts codepoints
    local result
    result=$(__tv_locale_in_child)
    assert_equal "$result" 'LC_CTYPE=C.UTF-8 LC_ALL=unset LANG=unset len=5'
    # A non-UTF-8 LC_ALL would override LC_CTYPE, so it must be cleared
    result=$(__tv_locale_in_child LC_ALL=C)
    assert_equal "$result" 'LC_CTYPE=C.UTF-8 LC_ALL=unset LANG=unset len=5'
}

function test_tv_locale_utf8_lang_left_untouched { #@test
    local result
    result=$(__tv_locale_in_child LANG=en_US.UTF-8)
    assert_equal "${result% len=*}" 'LC_CTYPE=unset LC_ALL=unset LANG=en_US.UTF-8'
}

function test_tv_sort_orders_raw_values { #@test
    # Without -s, sort_by ran per object and emptied the table
    local result
    result=$(__tv_in_child '{"k":2,"s":"b"}
{"k":10,"s":"c"}
{"k":null,"s":"n"}
{"k":1,"s":"a"}' \
        '__bu_tv_rebuild_cache
        __bu_tv_sort_by_column k
        echo "rc=$? rows=${#_TV_ROWS[@]} cells=${#_TV_CELLS[@]} $_TV_SORT_DIR perm=${_TV_SORT_PERM[*]}"
        printf "%s|" "${_TV_CELLS[@]}"; echo
        __bu_tv_sort_by_column k
        echo "rc=$? rows=${#_TV_ROWS[@]} cells=${#_TV_CELLS[@]} $_TV_SORT_DIR perm=${_TV_SORT_PERM[*]}"
        printf "%s|" "${_TV_CELLS[@]}"')
    assert_equal "$result" 'rc=0 rows=4 cells=8 asc perm=2 3 0 1
|n|1|a|2|b|10|c|
rc=0 rows=4 cells=8 desc perm=3 2 1 0
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

# ===========================================================================
# Performance guard: 500 rows x 6 cols frame must render in < 100ms
# ===========================================================================

function test_tv_frame_perf_500x6_under_100ms { #@test
    local ms
    ms=$(bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        for i in {1..500}; do
            _TV_ROWS+=("{\"name\":\"cmd-$i\",\"verb\":\"get\",\"noun\":\"item-$i\",\"namespace\":\"bu\",\"type\":\"source\",\"extra\":\"val-$i\"}")
        done
        _TV_NUM_ROWS=${#_TV_ROWS[@]}
        _TV_TERM_ROWS=46
        _TV_TERM_COLS=120
        __bu_tv_extract_columns ""
        __bu_tv_rebuild_cache
        __bu_tv_clamp_offsets
        __bu_tv_render_frame >/dev/null   # warm-up
        local start=${EPOCHREALTIME/.}
        for f in {1..5}; do __bu_tv_render_frame >/dev/null; done
        local end=${EPOCHREALTIME/.}
        echo $(( (end - start) / 5000 ))
    ')
    echo "frame time: ${ms}ms (limit 100ms)"
    (( ms < 100 ))
}

# ===========================================================================
# Interactive: driven through a real pty via script(1)
# ===========================================================================

function test_tv_interactive_scroll_tracks_keys { #@test
    command -v script >/dev/null || skip "script(1) not available"

    local rows_file=$BATS_TEST_TMPDIR/rows.jsonl
    local cap=$BATS_TEST_TMPDIR/cap.txt
    local i
    for i in {1..50}; do
        printf '{"name":"cmd-%s","version":"1.0"}\n' "$i"
    done > "$rows_file"

    # util-linux script takes the command via -c; BSD/macOS script has no -c
    # and takes it as trailing arguments after the capture file
    local -r inner="source \"$DIR\"/../activate >/dev/null 2>&1 && bu view-table < \"$rows_file\""
    local -a script_cmd=()
    if script -q -c true /dev/null >/dev/null 2>&1; then
        script_cmd=(script -q -c "bash -c '$inner'" "$cap")
    else
        script_cmd=(script -q "$cap" bash -c "$inner")
    fi

    # Feed 10x "j" then "q" through the pty; the viewer reads JSONL from the
    # file (stdin redirect) and keys from /dev/tty (the pty).
    {
        # Let the entrypoint load before feeding keys: keys typed before the
        # viewer owns the tty are swallowed by the intermediate shell, and
        # activation time varies wildly across hosts (CI, network
        # filesystems).  A pipe can't observe the frame, so be generous.
        sleep 8
        for i in {1..10}; do printf 'j'; sleep 0.05; done
        sleep 0.5
        printf 'q'
    } | timeout 30 "${script_cmd[@]}" >/dev/null

    # After 10x j the status line must show the viewport starting at row 11
    grep -q 'Rows 11-' "$cap"
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
    result=$(__tv_read_key_in_child </dev/null)
    assert_equal "$result" "q"
}

function test_tv_read_key_enter_maps_to_newline { #@test
    # read -n1 consumes the newline delimiter: rc=0, empty var -> $'\x0a'
    local result
    result=$(printf '\n' | __tv_read_key_in_child | od -An -tx1 | tr -d ' \n')
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

function test_tv_read_key_trapped_signal_returns_none { #@test
    # A trapped signal during the blocking read must yield the no-op
    # sentinel "none", NOT "q".  (On bash 5.2, read restarts after a
    # trapped signal, so this >128 path is exercised by stubbing read to
    # return 142 the way non-restarting platforms behave; live signal
    # survival is covered by the tmux WINCH test.)
    local result
    result=$(bash -c '
        source "'"$DIR"'/../bu_entrypoint.sh" >/dev/null 2>&1
        source "'"$DIR"'/../lib/core/bu_core_tv.sh"
        read() { return 142; }   # simulate signal-interrupted read (rc>128)
        __bu_tv_read_key 1
        printf "%s" "$_TV_KEY"
    ')
    assert_equal "$result" "none"
}

# ===========================================================================
# Job control: driven through tmux
# ===========================================================================

# ```md
# Poll a tmux pane until its capture matches a pattern (or tries run out).
# Fixed sleeps lose on loaded hosts; callers still assert on `pane`
# afterwards, so a timeout surfaces as the original assertion failure.
#
# Params:
# - $1: tmux socket
# - $2: target pane
# - $3: grep -E pattern to wait for
# - $4: max tries at 0.5s each (default 20)
#
# Returns:
# - pane: last captured frame (caller's local, via dynamic scope)
# ```
function __tv_wait_pane {
    local -r sock=$1 target=$2 pattern=$3
    local -r -i tries=${4:-20}
    local -i _w
    for (( _w = 0; _w < tries; _w++ )); do
        pane=$(tmux -L "$sock" capture-pane -t "$target" -p)
        grep -qE "$pattern" <<<"$pane" && break
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
    __tv_wait_pane "$1" "$2" 'Rows [0-9]+-' 120
    printf '%s' "$rows"
}

function test_tv_tmux_suspend_resume_cycle { #@test
    command -v tmux >/dev/null || skip "tmux not available"

    local sock="tvsus$$"
    __tv_tmux_setup "$sock" tvsus >/dev/null

    local pane
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'Rows 1-' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # Scroll down 3 (coalesced into one render)
    tmux -L "$sock" send-keys -t tvsus jjj
    __tv_wait_pane "$sock" tvsus 'Rows 4-'
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'Rows 4-' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # Ctrl-Z: job reports Stopped, pane shows the normal shell (not the TUI)
    tmux -L "$sock" send-keys -t tvsus C-z
    # The shell prints its Stopped notice at its own pace under load
    __tv_wait_pane "$sock" tvsus 'Stopped'
    if grep -q 'Rows 4-' <<<"$pane"; then
        echo "TUI still on screen after C-z:"; echo "$pane"
        tmux -L "$sock" kill-server; return 1
    fi
    grep -q 'Stopped' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # fg: the frame repaints at the same offset
    tmux -L "$sock" send-keys -t tvsus "fg" Enter
    __tv_wait_pane "$sock" tvsus 'Rows 4-'
    grep -q 'Rows 4-' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # Scrolling still works after resume
    tmux -L "$sock" send-keys -t tvsus j
    __tv_wait_pane "$sock" tvsus 'Rows 5-'
    grep -q 'Rows 5-' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # A signal delivered during the blocking read must not exit the viewer
    pkill -WINCH -f 'bu-view-table.sh'
    sleep 0.4
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'Rows 5-' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # q returns the prompt with rc 0
    tmux -L "$sock" send-keys -t tvsus q
    # Wait for the viewer to release the screen; keys sent earlier would be
    # read by the TUI instead of the shell
    local -i _w
    for (( _w = 0; _w < 20; _w++ )); do
        pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
        grep -qE 'Rows [0-9]+-' <<<"$pane" || break
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
    # 30-line pane -> 27 data rows (status 1-27); 20 lines -> 17.
    command -v tmux >/dev/null || skip "tmux not available"

    local sock="tvsize$$"
    local pane
    __tv_tmux_setup "$sock" tvsize >/dev/null
    pane=$(tmux -L "$sock" capture-pane -t tvsize -p)
    grep -q 'Rows 1-27/50' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # SIGWINCH path: only the WINCH handler re-reads the size, so the frame
    # after the next key must use it.  (The handler runs once the blocking
    # read returns, so the key is what triggers the redraw.)
    tmux -L "$sock" resize-window -t tvsize -x 100 -y 20
    sleep 0.5
    tmux -L "$sock" send-keys -t tvsize j
    __tv_wait_pane "$sock" tvsize 'Rows 2-18/50'
    grep -q 'Rows 2-18/50' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    tmux -L "$sock" send-keys -t tvsize q
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
    __tv_wait_pane "$sock" tvbg 'foreground group|Rows [0-9]+-' 120
    grep -q "foreground group" <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }
    if grep -q 'Rows 1-' <<<"$pane"; then
        echo "TUI started despite background process group:"; echo "$pane"
        tmux -L "$sock" kill-server; return 1
    fi

    tmux -L "$sock" kill-server
}
