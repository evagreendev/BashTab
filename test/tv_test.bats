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
