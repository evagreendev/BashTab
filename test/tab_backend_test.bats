#!/usr/bin/env bats

# Tests for the Tab backends other than the positioned fzf dropdown
# (BU_AUTOCOMPLETE_TAB_BACKEND, lib/core/bu_core_autocomplete.sh):
# - fzf-cheap: the fzf dropdown on the prompt row, no terminal queries
# - readline:  readline's own completion, fed by a prepare handler that
#              stashes the line and swaps the command's compspec for one
#              `complete`, whose function runs the engine and adds the
#              descriptions
#
# The helpers are tested in this shell; the backends drive a real interactive
# `bash --norc` inside a detached tmux server, as bind_x_test.bats does.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    source "$DIR"/../bu_entrypoint.sh
    source "$BU_NULL"
    TB_SOCK=
}

teardown() {
    # A failed assertion ends the test before its own kill-server
    if [[ -n "$TB_SOCK" ]]; then
        tmux -L "$TB_SOCK" kill-server 2>/dev/null || true
    fi
}

# ```md
# Poll a tmux pane until its capture matches a pattern, or tries run out.
#
# Params:
# - $1: tmux socket
# - $2: target pane
# - $3: grep -E pattern to wait for
# - $4: max tries at 0.5s each (default 20)
#
# Returns:
# - pane: last captured frame (caller's local, via dynamic scope)
# - Exit code: 0 when the pattern showed up
# ```
function __tb_wait_pane {
    local -i _w
    for (( _w = 0; _w < ${4:-20}; _w++ )); do
        pane=$(tmux -L "$1" capture-pane -t "$2" -p)
        grep -qE -e "$3" <<<"$pane" && return 0
        sleep 0.5
    done
    return 1
}

# ```md
# Start a detached tmux session running `bash --norc` with BashTab activated
# and Tab bound to the given backend.
#
# Params:
# - $1: tmux socket
# - $2: session name
# - $3: Tab backend
# ```
function __tb_tmux_setup {
    local pane
    command -v tmux >/dev/null || skip "tmux not available"
    TB_SOCK=$1
    # fd 3 closed: bats waits for every holder of its output fd to exit
    tmux -L "$1" new-session -d -s "$2" -x 120 -y 30 "bash --norc" 3>&-
    tmux -L "$1" send-keys -t "$2" "PS1='tb\$ '; source \"$DIR\"/../activate >/dev/null 2>&1; bu_autocomplete_enable_tab $3 >/dev/null 2>&1; clear; echo tb-ready" Enter
    # Activation time varies wildly across hosts: wait (up to 60s).
    __tb_wait_pane "$1" "$2" '^tb-ready' 120 || { tmux -L "$1" kill-server; fail "shell did not start"; }
}

# MARK: ANSI stripping

function test_strip_ansi_arrays_sequences { #@test
    local -a a=(
        $'\e[33mget-alias\e[m\017'
        $'\e(B\e[mplain'
        $'\e]133;A\a'
        $'x\e]8;;http://a\e\\link\e]8;;\e\\y'
        $'\e[1;38;5;174mbold\e[0m'
    )
    __bu_autocomplete_strip_ansi_arrays a
    assert_equal "${#a[@]}" 5
    assert_equal "${a[0]}" get-alias
    assert_equal "${a[1]}" plain
    assert_equal "${a[2]}" ''
    assert_equal "${a[3]}" xlinky
    assert_equal "${a[4]}" bold
}

function test_strip_ansi_arrays_keeps_plain_text { #@test
    # Text that looks like the inside of a sequence is left alone when no ESC
    # precedes it, also at the very start of the first element
    local -a a=('[first' $'\e[1m[x' '(B' ']notosc' '' $'multi\nline' 'last')
    local -a b=(plain words '' x)
    local -a e=()
    __bu_autocomplete_strip_ansi_arrays a b e
    assert_equal "${#a[@]}" 7
    assert_equal "${a[0]}" '[first'
    assert_equal "${a[1]}" '[x'
    assert_equal "${a[2]}" '(B'
    assert_equal "${a[3]}" ']notosc'
    assert_equal "${a[4]}" ''
    assert_equal "${a[5]}" $'multi\nline'
    assert_equal "${a[6]}" last
    assert_equal "${b[*]}" "plain words  x"
    assert_equal "${#b[@]}" 4
    assert_equal "${#e[@]}" 0
}

# MARK: readline descriptions

function test_readline_describe_aligns_and_truncates { #@test
    COLUMNS=60
    COMPREPLY=(get-alias get-all-the-things get-x)
    BU_COMPREPLY_METADATA=("flag alias" "" "a very long description that will not fit in the remaining width of the terminal")
    __bu_autocomplete_readline_describe
    assert_equal "${COMPREPLY[0]}" "get-alias           (flag alias)"
    # No description: left bare
    assert_equal "${COMPREPLY[1]}" "get-all-the-things"
    # 60 columns: the string pins it (${#} would count the … as 3 bytes
    # under the C locale bats runs in)
    assert_equal "${COMPREPLY[2]}" "get-x               (a very long description that will not…)"
}

function test_readline_describe_common_prefix_stops_before_padding { #@test
    # Readline inserts the common prefix of the candidates: it must never
    # reach into the padding or the description
    COLUMNS=80
    COMPREPLY=(--format --from)
    BU_COMPREPLY_METADATA=("Output format" "Output format")
    __bu_autocomplete_readline_describe
    local prefix=${COMPREPLY[0]} c
    for c in "${COMPREPLY[@]}"; do
        while [[ "$c" != "$prefix"* ]]; do prefix=${prefix%?}; done
    done
    assert_equal "$prefix" "--f"
}

function test_readline_describe_leaves_single_candidate_bare { #@test
    COMPREPLY=(only)
    BU_COMPREPLY_METADATA=(description)
    __bu_autocomplete_readline_describe
    assert_equal "${COMPREPLY[*]}" only
}

function test_readline_describe_without_descriptions_is_a_no_op { #@test
    COMPREPLY=(a bb ccc)
    BU_COMPREPLY_METADATA=()
    __bu_autocomplete_readline_describe
    assert_equal "${COMPREPLY[*]}" "a bb ccc"
}

function test_readline_describe_narrow_terminal_skips_alignment { #@test
    COLUMNS=20
    COMPREPLY=(a-rather-long-word b)
    BU_COMPREPLY_METADATA=(desc1 desc2)
    __bu_autocomplete_readline_describe
    # 20 - 17 - 4 = no room to align: each description gets what is left
    assert_equal "${COMPREPLY[0]}" "a-rather-long-word"
    assert_equal "${COMPREPLY[1]}" "b  (desc2)"
}

# MARK: readline stash

function _tb_orig_completion { COMPREPLY=(original); }
function _tb_format_completion { COMPREPLY=(--format=json --format=jsonl); }
function _tb_empty_completion { COMPREPLY=(); }

# ```md
# Put the readline backend in the state its prepare handler leaves: the
# command's compspec swapped for the stash function, the line stashed.
#
# Params:
# - $1: compspec function the command really has
# - $2: line in front of the cursor, as the handler saw it
# - $3...: its words, as __bu_autocomplete_tab_parse_line split them
# ```
function __tb_stash_line {
    local func=$1 front=$2
    shift 2
    complete -F "$func" tbcmd
    __BU_AUTOCOMPLETE_RL_SWAPPED_COMMAND=tbcmd
    __BU_AUTOCOMPLETE_RL_SWAPPED_SPEC=$(complete -p tbcmd)
    complete -F __bu_autocomplete_readline_stash_func tbcmd
    __BU_AUTOCOMPLETE_RL_STASH_COMMAND_LINE=("$@")
    __BU_AUTOCOMPLETE_RL_STASH_BEFORE_PIPE=${front%"$*"}
    __BU_AUTOCOMPLETE_RL_STASH_FRONT=$front
    __BU_AUTOCOMPLETE_RL_STASH_IS_SET=true
}

function test_readline_stash_func_runs_engine_drops_wordbreak_prefix_and_restores_spec { #@test
    __tb_stash_line _tb_format_completion 'echo x | tbcmd --format=js' tbcmd --format=js

    # What readline passes: the command after the pipe, and as $2 only the
    # text after the last COMP_WORDBREAKS character
    COMP_LINE='tbcmd --format=js'
    COMP_POINT=${#COMP_LINE}
    COMPREPLY=()
    local rc=0
    __bu_autocomplete_readline_stash_func tbcmd js = || rc=$?
    assert_equal "$rc" 0
    assert_equal "${COMPREPLY[*]}" "json jsonl"
    assert_equal "$(complete -p tbcmd)" "complete -F _tb_format_completion tbcmd"
    assert_equal "$__BU_AUTOCOMPLETE_RL_STASH_IS_SET" false
}

function test_readline_stash_func_stale_stash_retries_original { #@test
    __tb_stash_line _tb_orig_completion 'tbcmd x' tbcmd x

    # Another line than the one the stash was made for: 124 makes bash
    # restart completion with the (restored) original compspec
    COMP_LINE='tbcmd other'
    COMP_POINT=${#COMP_LINE}
    COMPREPLY=()
    local rc=0
    __bu_autocomplete_readline_stash_func tbcmd other tbcmd || rc=$?
    assert_equal "$rc" 124
    assert_equal "${#COMPREPLY[@]}" 0
    assert_equal "$(complete -p tbcmd)" "complete -F _tb_orig_completion tbcmd"
}

function test_readline_stash_func_nothing_to_add_retries_original { #@test
    __tb_stash_line _tb_empty_completion 'tbcmd x' tbcmd x
    COMP_LINE='tbcmd x'
    COMP_POINT=${#COMP_LINE}
    COMPREPLY=(leftover)
    local rc=0
    __bu_autocomplete_readline_stash_func tbcmd x tbcmd || rc=$?
    assert_equal "$rc" 124
    assert_equal "${#COMPREPLY[@]}" 0
    assert_equal "$(complete -p tbcmd)" "complete -F _tb_empty_completion tbcmd"
}

function _tb_probe_completion {
    TB_SEEN_COMP_TYPE=${COMP_TYPE-unset}
    COMPREPLY=(alpha beta)
}

function test_readline_stash_func_hides_bash_completion_variables { #@test
    __tb_stash_line _tb_probe_completion 'tbcmd ' tbcmd ''
    COMP_LINE='tbcmd '
    COMP_POINT=${#COMP_LINE}
    COMP_TYPE=63
    COMP_KEY=9
    TB_SEEN_COMP_TYPE=
    __bu_autocomplete_readline_stash_func tbcmd '' tbcmd
    assert_equal "$TB_SEEN_COMP_TYPE" unset
    # Bash's own values are back once the function returns
    assert_equal "$COMP_TYPE" 63
}

function _tb_logging_completion {
    bu_log_err "completer says hi"
    COMPREPLY=(alpha beta)
}

function test_readline_stash_func_queues_engine_log_for_printing { #@test
    BU_AUTOCOMPLETE_LOG_LVL=$BU_LOG_LVL_ERR
    __BU_AUTOCOMPLETE_RL_LOG_FILE=$BATS_TEST_TMPDIR/rl.log
    local bound=
    __bu_autocomplete_bind_x() { bound="$*"; }
    __tb_stash_line _tb_logging_completion 'tbcmd ' tbcmd ''
    COMP_LINE='tbcmd '
    COMP_POINT=${#COMP_LINE}
    __bu_autocomplete_readline_stash_func tbcmd '' tbcmd 2>"$BATS_TEST_TMPDIR/stderr"
    # Nothing reached the terminal (stderr here): it went to the log file
    assert_equal "$(< "$BATS_TEST_TMPDIR/stderr")" ''
    grep -q 'completer says hi' "$__BU_AUTOCOMPLETE_RL_LOG_FILE" || fail "not logged: $(< "$__BU_AUTOCOMPLETE_RL_LOG_FILE")"
    assert_equal "$bound" "$__BU_AUTOCOMPLETE_RL_LOG_KEYSEQ __bu_bind_readline_tab_print_log"
    assert_equal "$__BU_LOG_AUTOCOMPLETE_OUT" /dev/tty
}

function test_readline_stash_func_without_log_binds_nothing { #@test
    __BU_AUTOCOMPLETE_RL_LOG_FILE=$BATS_TEST_TMPDIR/rl.log
    local bound=
    __bu_autocomplete_bind_x() { bound="$*"; }
    __tb_stash_line _tb_format_completion 'tbcmd --format=js' tbcmd --format=js
    COMP_LINE='tbcmd --format=js'
    COMP_POINT=${#COMP_LINE}
    __bu_autocomplete_readline_stash_func tbcmd --format=js tbcmd
    assert_equal "$bound" ''
    [[ ! -s "$__BU_AUTOCOMPLETE_RL_LOG_FILE" ]] || fail "log not empty: $(< "$__BU_AUTOCOMPLETE_RL_LOG_FILE")"
}

function test_readline_print_log_prints_empties_and_unbinds { #@test
    __BU_AUTOCOMPLETE_RL_LOG_FILE=$BATS_TEST_TMPDIR/rl.log
    printf '%s\n' 'ERR one' 'ERR two' > "$__BU_AUTOCOMPLETE_RL_LOG_FILE"
    local bound=
    bind() { bound="$*"; }
    run __bu_bind_readline_tab_print_log
    assert_success
    assert_output $'ERR one\nERR two'
    __bu_bind_readline_tab_print_log 2>/dev/null
    assert_equal "$bound" '"\C-x\C-_l": ""'
    [[ ! -s "$__BU_AUTOCOMPLETE_RL_LOG_FILE" ]] || fail "log not emptied"
}

# MARK: compopt

function test_compopt_record_only_records_without_the_builtin { #@test
    BU_COMPOPT_DYNAMIC_COMPLETION_OPTIONS=()
    __BU_COMPOPT_RECORD_ONLY=true
    local rc=0
    # Outside a completion function the builtin would fail
    compopt -o plusdirs 2>/dev/null || rc=$?
    __BU_COMPOPT_RECORD_ONLY=false
    assert_equal "$rc" 0
    assert_equal "${BU_COMPOPT_DYNAMIC_COMPLETION_OPTIONS[plusdirs]}" -o
}

function test_compopt_record_only_still_applies_to_a_named_command { #@test
    complete -F _tb_orig_completion tbcmd
    __BU_COMPOPT_RECORD_ONLY=true
    compopt -o nospace tbcmd
    __BU_COMPOPT_RECORD_ONLY=false
    assert_equal "$(complete -p tbcmd)" "complete -o nospace -F _tb_orig_completion tbcmd"
}

function test_compopt_calls_the_builtin_by_default { #@test
    local rc=0
    compopt -o plusdirs 2>/dev/null || rc=$?
    # Not in a completion function: the builtin's failure shows it ran
    assert_equal "$rc" 1
}

function test_readline_restore_spec_removes_spec_the_command_did_not_have { #@test
    complete -r tbnospec 2>/dev/null || true
    __BU_AUTOCOMPLETE_RL_SWAPPED_COMMAND=tbnospec
    __BU_AUTOCOMPLETE_RL_SWAPPED_SPEC=
    complete -F __bu_autocomplete_readline_stash_func tbnospec
    __bu_autocomplete_readline_restore_spec
    run complete -p tbnospec
    assert_failure
    assert_equal "$__BU_AUTOCOMPLETE_RL_SWAPPED_COMMAND" ''
}

# MARK: Interactive

function test_readline_backend_binds_tab_to_the_macro { #@test
    local sock=tb$$a pane out=$BATS_TEST_TMPDIR/bind.txt
    __tb_tmux_setup "$sock" tbbind readline
    tmux -L "$sock" send-keys -t tbbind "{ bind -X; bind -s; echo \"backend=\$BU_AUTOCOMPLETE_ACTIVE_TAB_BACKEND\"; } > \"$out\"" Enter
    __tb_wait_pane "$sock" tbbind 'tb\$ $' 20 || true
    sleep 0.5
    tmux -L "$sock" kill-server
    grep -q '__bu_bind_readline_tab_prepare' "$out" || fail "prepare handler not bound: $(< "$out")"
    grep -qF '"\C-i": "\C-x\C-_t\C-x\C-_c\C-x\C-_l"' "$out" || fail "Tab macro not bound: $(< "$out")"
    grep -q '^backend=readline$' "$out" || fail "backend not recorded: $(< "$out")"
}

function test_readline_backend_completes_single_candidate { #@test
    local sock=tb$$b pane
    __tb_tmux_setup "$sock" tbone readline
    tmux -L "$sock" send-keys -t tbone 'bu get-al' Tab
    local rc=0
    __tb_wait_pane "$sock" tbone 'tb\$ bu get-alias' 20 || rc=$?
    tmux -L "$sock" kill-server
    ((rc == 0)) || fail "not completed: $pane"
}

function test_readline_backend_lists_candidates_with_descriptions { #@test
    local sock=tb$$c pane
    __tb_tmux_setup "$sock" tblist readline
    # First Tab: nothing to insert (common prefix = the word); the second
    # Tab on the same line lists, as readline does
    tmux -L "$sock" send-keys -t tblist 'bu query-object --f' Tab
    sleep 1
    tmux -L "$sock" send-keys -t tblist Tab
    local rc=0
    __tb_wait_pane "$sock" tblist '^--format +\(.*[Oo]utput format' 20 || rc=$?
    tmux -L "$sock" kill-server
    ((rc == 0)) || fail "no described list: $pane"
    # The descriptions are never inserted into the line
    grep -qE 'tb\$ bu query-object --f$' <<<"$pane" || fail "line changed: $pane"
}

function test_readline_backend_leaves_original_compspec_in_place { #@test
    local sock=tb$$d pane out=$BATS_TEST_TMPDIR/spec.txt
    __tb_tmux_setup "$sock" tbspec readline
    tmux -L "$sock" send-keys -t tbspec 'bu get-al' Tab
    __tb_wait_pane "$sock" tbspec 'tb\$ bu get-alias' 20 || true
    tmux -L "$sock" send-keys -t tbspec C-u "complete -p bu > \"$out\"" Enter
    sleep 1
    tmux -L "$sock" kill-server
    assert_equal "$(< "$out")" "complete -F __bu_autocomplete_completion_func_cli bu"
}

function test_readline_backend_prints_engine_log_above_the_prompt { #@test
    local sock=tb$$e pane
    __tb_tmux_setup "$sock" tblog readline
    tmux -L "$sock" send-keys -t tblog "BU_AUTOCOMPLETE_LOG_LVL=\$BU_LOG_LVL_ERR; _tblog() { bu_log_err 'completer says hi'; COMPREPLY=(alpha beta); }; tblog() { :; }; complete -F _tblog tblog; clear" Enter
    __tb_wait_pane "$sock" tblog 'tb\$ $' 20 || true
    tmux -L "$sock" send-keys -t tblog 'tblog ' Tab
    local rc=0
    __tb_wait_pane "$sock" tblog 'completer says hi' 20 || rc=$?
    sleep 0.5
    pane=$(tmux -L "$sock" capture-pane -t tblog -p)
    tmux -L "$sock" kill-server
    ((rc == 0)) || fail "log not shown: $pane"
    # The message on its own row, the line redrawn intact below it
    grep -qE '^ERR .*completer says hi' <<<"$pane" || fail "message not on its own row: $pane"
    grep -qE 'tb\$ tblog *$' <<<"$pane" || fail "line not redrawn: $pane"
}

function test_fzf_cheap_backend_completes_single_candidate { #@test
    command -v fzf >/dev/null || skip "fzf not available"
    local sock=tb$$e pane
    __tb_tmux_setup "$sock" tbcheap fzf-cheap
    # --select-1: a single match is inserted without opening fzf
    tmux -L "$sock" send-keys -t tbcheap 'bu get-al' Tab
    local rc=0
    __tb_wait_pane "$sock" tbcheap 'tb\$ bu get-alias' 20 || rc=$?
    tmux -L "$sock" kill-server
    ((rc == 0)) || fail "not completed: $pane"
}

function test_fzf_cheap_backend_picks_from_the_dropdown { #@test
    command -v fzf >/dev/null || skip "fzf not available"
    local sock=tb$$f pane
    __tb_tmux_setup "$sock" tbpick fzf-cheap
    tmux -L "$sock" send-keys -t tbpick 'bu query-object --f' Tab
    # The line in front of the word is fzf's prompt; metadata beside each
    # candidate
    __tb_wait_pane "$sock" tbpick '--format +.*[Oo]utput format' 20 || { tmux -L "$sock" kill-server; fail "no dropdown: $pane"; }
    grep -qE '^bu query-object --f' <<<"$pane" || { tmux -L "$sock" kill-server; fail "no prompt: $pane"; }
    tmux -L "$sock" send-keys -t tbpick 'o'
    __tb_wait_pane "$sock" tbpick '1/3' 20 || true
    tmux -L "$sock" send-keys -t tbpick Enter
    local rc=0
    __tb_wait_pane "$sock" tbpick 'tb\$ bu query-object --format' 20 || rc=$?
    tmux -L "$sock" kill-server
    ((rc == 0)) || fail "not inserted: $pane"
}
