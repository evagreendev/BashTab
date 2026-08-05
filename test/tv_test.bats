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

    # Feed 10x "j" then "q" through the pty; the viewer reads JSONL from the
    # file (stdin redirect) and keys from /dev/tty (the pty).
    {
        sleep 1                       # let the entrypoint load
        for i in {1..10}; do printf 'j'; sleep 0.05; done
        sleep 0.5
        printf 'q'
    } | timeout 20 script -q -c \
        "bash -c 'source \"$DIR\"/../activate >/dev/null 2>&1 && bu view-table' < \"$rows_file\"" \
        "$cap" >/dev/null

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

function __tv_tmux_setup { # $1=socket $2=session
    local rows=$BATS_TEST_TMPDIR/rows.$2.jsonl
    local i
    for i in {1..50}; do printf '{"name":"cmd-%s","version":"1.0"}\n' "$i"; done > "$rows"
    tmux -L "$1" new-session -d -s "$2" -x 100 -y 30 "bash --norc"
    tmux -L "$1" send-keys -t "$2" "source \"$DIR\"/../activate >/dev/null 2>&1; bu view-table < \"$rows\"" Enter
    sleep 2.5
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
    sleep 0.4
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'Rows 4-' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # Ctrl-Z: job reports Stopped, pane shows the normal shell (not the TUI)
    tmux -L "$sock" send-keys -t tvsus C-z
    sleep 0.5
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    if grep -q 'Rows 4-' <<<"$pane"; then
        echo "TUI still on screen after C-z:"; echo "$pane"
        tmux -L "$sock" kill-server; return 1
    fi
    grep -q 'Stopped' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # fg: the frame repaints at the same offset
    tmux -L "$sock" send-keys -t tvsus "fg" Enter
    sleep 0.6
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'Rows 4-' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # Scrolling still works after resume
    tmux -L "$sock" send-keys -t tvsus j
    sleep 0.4
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'Rows 5-' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # A signal delivered during the blocking read must not exit the viewer
    pkill -WINCH -f 'bu-view-table.sh'
    sleep 0.4
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'Rows 5-' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

    # q returns the prompt with rc 0
    tmux -L "$sock" send-keys -t tvsus q
    sleep 0.5
    tmux -L "$sock" send-keys -t tvsus "echo VIEWER_RC=\$?" Enter
    sleep 0.4
    pane=$(tmux -L "$sock" capture-pane -t tvsus -p)
    grep -q 'VIEWER_RC=0' <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }

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
    sleep 2.5

    # Backgrounded pipeline: not the tty's foreground group -> loud refusal,
    # NOT a silent kernel stop of the pipeline.
    local pane
    pane=$(tmux -L "$sock" capture-pane -t tvbg -p)
    grep -q "foreground group" <<<"$pane" || { echo "$pane"; tmux -L "$sock" kill-server; return 1; }
    if grep -q 'Rows 1-' <<<"$pane"; then
        echo "TUI started despite background process group:"; echo "$pane"
        tmux -L "$sock" kill-server; return 1
    fi

    tmux -L "$sock" kill-server
}
