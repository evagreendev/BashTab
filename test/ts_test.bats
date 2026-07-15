#!/usr/bin/env bats

# Comprehensive tests for tree-sitter daemon output (via bu_ts_parse)
# and end-to-end completion dispatch.
#
# Requires: BU_AUTOCOMPLETE_USE_TREE_SITTER=true

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    source "$DIR"/../bu_entrypoint.sh
    source "$BU_NULL"

    if [[ -f /usr/share/bash-completion/bash_completion ]]; then
        source /usr/share/bash-completion/bash_completion
    fi

    BU_AUTOCOMPLETE_USE_TREE_SITTER=true
}

teardown() {
    bu_ts_daemon_stop 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: call bu_ts_parse and assert key result fields.
# Usage: assert_ts FIELD VALUE INPUT OFFSET
# ---------------------------------------------------------------------------
assert_ts() {
    local field=$1 expected=$2 input=$3 offset=$4
    bu_ts_parse "$offset" "$input" 2>/dev/null
    local actual=${BU_TS_RESULT[$field]}
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: $field expected [$expected] got [$actual]  input=[$input] offset=$offset" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Helper: get completions via tree-sitter dispatch and check count + content.
# Usage: assert_completions EXPECTED_COUNT FIRST_EXPECTED INPUT OFFSET
# ---------------------------------------------------------------------------
assert_completions() {
    local expected_count=$1 expected_first=$2 input=$3 offset=$4
    bu_ts_parse "$offset" "$input" 2>/dev/null

    local -a cmd_words=()
    local _saved_ifs=$IFS
    IFS=$'\037'
    cmd_words=(${BU_TS_RESULT[cmdWords]})
    IFS=$_saved_ifs
    if [[ "${BU_TS_RESULT[original]:${#BU_TS_RESULT[original]}-1}" = ' ' ]]; then
        cmd_words+=("")
    fi

    COMPREPLY=()
    local kind=${BU_TS_RESULT[cursor,completeKind]}
    case "$kind" in
    dollar_word)
        local rt=${BU_TS_RESULT[cursor,replaceText]}
        COMPREPLY=($(compgen -A variable -P '$' -- "${rt#\$}"))
        ;;
    dollar_brace)
        local rt=${BU_TS_RESULT[cursor,replaceText]}
        COMPREPLY=($(compgen -A variable -P '${' -S '}' -- "${rt#\$\{}"))
        ;;
    *)
        bu_autocomplete_get_autocompletions --accept-ansi-colors "${cmd_words[@]}" 2>/dev/null
        ;;
    esac

    local count=${#COMPREPLY[@]}
    if (( count != expected_count && expected_count >= 0 )); then
        echo "FAIL: completion count expected $expected_count got $count  input=[$input]" >&2
        return 1
    fi

    if [[ -n "$expected_first" ]]; then
        # Strip ANSI from first completion for comparison
        local first=$(sed -r $'s/\x1B\\[[0-9;]*[mGK]//g' <<<"${COMPREPLY[0]}")
        first=$(sed -r $'s/\x1B\\(B//g' <<<"$first")
        if [[ "$first" != "$expected_first"* ]]; then
            echo "FAIL: first completion expected to start with [$expected_first] got [$first]  input=[$input]" >&2
            return 1
        fi
    fi
}

# ===========================================================================
# DAEMON OUTPUT: basic fields
# ===========================================================================

function test_ts_basic_cmdName { #@test
    assert_ts cmdName "bu"          "bu "           3
    assert_ts cmdName "git"         "git status"    3
    assert_ts cmdName "echo"        "echo hi"       2
    assert_ts cmdName "ls"          "  ls  -la"     2
}

function test_ts_basic_original { #@test
    assert_ts original "bu "        "bu "           3
    assert_ts original 'echo $HO'   'echo $HO'      8
}

function test_ts_basic_hasError { #@test
    assert_ts hasError "false"      "echo hello"    5
    assert_ts hasError "true"       'echo "$HO'     9
}

# ===========================================================================
# DAEMON OUTPUT: pipeBefore / pipeAfter splitting
# ===========================================================================

function test_ts_pipe_simple { #@test
    assert_ts pipeBefore ""         "echo hi"       4
    assert_ts pipeAfter  "echo hi"  "echo hi"       4
}

function test_ts_pipe_with_separator { #@test
    assert_ts pipeBefore "a | "     "a | b"         4
    assert_ts pipeAfter  "b"        "a | b"         4
}

function test_ts_pipe_or { #@test
    assert_ts pipeBefore "a || "    "a || b"        5
    assert_ts pipeAfter  "b"        "a || b"        5
}

function test_ts_pipe_and { #@test
    assert_ts pipeBefore "a && "    "a && b"        5
    assert_ts pipeAfter  "b"        "a && b"        5
}

function test_ts_pipe_semicolon { #@test
    assert_ts pipeBefore "a; "      "a; b"          4
    assert_ts pipeAfter  "b"        "a; b"          4
}

function test_ts_pipe_multi { #@test
    assert_ts pipeBefore "a | b | " "a | b | c"     8
    assert_ts pipeAfter  "c"        "a | b | c"     8
}

# ===========================================================================
# DAEMON OUTPUT: cmdWords (preserving trailing empty)
# ===========================================================================

function test_ts_cmdWords_trailing_space { #@test
    bu_ts_parse 3 "bu " 2>/dev/null
    local raw=${BU_TS_RESULT[cmdWords]}
    # Should have unit separator for second (empty) element
    [[ "$raw" = *$'\037' ]]
}

function test_ts_cmdWords_no_trailing { #@test
    bu_ts_parse 2 "bu" 2>/dev/null
    local raw=${BU_TS_RESULT[cmdWords]}
    # Should NOT have trailing unit separator
    [[ "$raw" != *$'\037' ]]
}

function test_ts_cmdWords_multiple { #@test
    bu_ts_parse 10 "bu get-command --verb " 2>/dev/null
    local raw=${BU_TS_RESULT[cmdWords]}
    # Three words, last empty due to trailing space
    local count=0
    local _saved_ifs=$IFS
    IFS=$'\037'
    local -a words=($raw)
    IFS=$_saved_ifs
    # bash drops trailing empty from array assignment
    # but we check that there are at least 3 separators
    [[ "$raw" == *$'\037'*$'\037'* ]]
}

# ===========================================================================
# DAEMON OUTPUT: dollar_word / variable expansions
# ===========================================================================

function test_ts_dollar_outside_quotes { #@test
    assert_ts "cursor,completeKind" "dollar_word"  'echo $HOME'  10
    assert_ts "cursor,replaceStart"  "5"            'echo $HOME'  10
    assert_ts "cursor,replaceEnd"    "10"            'echo $HOME'  10
    assert_ts "cursor,replaceText"   '$HOME'        'echo $HOME'  10
}

function test_ts_dollar_partial { #@test
    assert_ts "cursor,completeKind" "dollar_word"  'echo $HO'    8
    assert_ts "cursor,replaceText"  '$HO'           'echo $HO'    8
    assert_ts "cursor,replaceStart" "5"             'echo $HO'    8
    assert_ts "cursor,replaceEnd"   "8"             'echo $HO'    8
}

function test_ts_dollar_inside_quotes { #@test
    assert_ts "cursor,completeKind" "dollar_word"  'echo "$HOME"'  10
    assert_ts "cursor,replaceStart"  "6"            'echo "$HOME"'  10
    assert_ts "cursor,replaceEnd"    "11"           'echo "$HOME"'  10
}

function test_ts_dollar_inside_quotes_partial { #@test
    assert_ts "cursor,completeKind" "dollar_word"  'echo "$HO'    9
    assert_ts "cursor,replaceText"  '$HO'           'echo "$HO'    9
    assert_ts "cursor,replaceStart" "6"             'echo "$HO'    9
    assert_ts "cursor,replaceEnd"   "9"             'echo "$HO'    9
}

function test_ts_dollar_with_prefix_in_quotes { #@test
    # "2020-11-$HO" — only $HO should be replaced, not the prefix
    assert_ts "cursor,completeKind" "dollar_word"  'echo "2020-11-$HO'  17
    assert_ts "cursor,replaceStart"  "14"           'echo "2020-11-$HO'  17
    assert_ts "cursor,replaceEnd"    "17"           'echo "2020-11-$HO'  17
    assert_ts "cursor,replaceText"   '$HO'          'echo "2020-11-$HO'  17
}

function test_ts_dollar_brace_outside { #@test
    assert_ts "cursor,completeKind" "dollar_brace" 'echo ${HOME}'  11
    assert_ts "cursor,replaceStart"  "5"            'echo ${HOME}'  11
    assert_ts "cursor,replaceEnd"    "12"           'echo ${HOME}'  11
}

function test_ts_dollar_brace_partial { #@test
    assert_ts "cursor,completeKind" "dollar_brace" 'echo ${HO'    9
    assert_ts "cursor,replaceStart"  "5"            'echo ${HO'    9
    assert_ts "cursor,replaceEnd"    "9"            'echo ${HO'    9
}

function test_ts_dollar_brace_in_quotes { #@test
    assert_ts "cursor,completeKind" "dollar_brace" 'echo "${HO'   10
}

# ===========================================================================
# DAEMON OUTPUT: command substitution nested context
# ===========================================================================

function test_ts_cmdsub_basic { #@test
    # ls $(g  — cursor on g inside command substitution
    bu_ts_parse 6 'ls $(g' 2>/dev/null
    assert_equal "${BU_TS_RESULT[cmdName]}"          "g"
    assert_equal "${BU_TS_RESULT[cursor,completeKind]}" "command"
    # pipeBefore should include the $( opener
    [[ "${BU_TS_RESULT[pipeBefore]}" == "ls \$("* || "${BU_TS_RESULT[pipeBefore]}" == "ls \$("* ]]
    assert_equal "${BU_TS_RESULT[pipeAfter]}"         "g"
}

function test_ts_cmdsub_with_args { #@test
    # ls $(git st  — cursor on st, inside command substitution
    bu_ts_parse 10 'ls $(git st' 2>/dev/null
    assert_equal "${BU_TS_RESULT[cmdName]}" "git"
    # cmdWords should include git and st
    local raw=${BU_TS_RESULT[cmdWords]}
    [[ "$raw" == "git"*"st" ]]
}

function test_ts_cmdsub_inner_pipe { #@test
    # echo $(ls | grep t  — inner pipe inside $()
    bu_ts_parse 15 'echo $(ls | grep t' 2>/dev/null
    assert_equal "${BU_TS_RESULT[cmdName]}" "grep"
    [[ "${BU_TS_RESULT[pipeAfter]}" == "grep "* ]]
}

function test_ts_cmdsub_outer_pipe_still_works { #@test
    # echo $(ls) | grep tx  — cursor OUTSIDE substitution, outer pipe splits
    bu_ts_parse 20 'echo $(ls) | grep tx' 2>/dev/null
    assert_equal "${BU_TS_RESULT[cmdName]}" "grep"
    assert_equal "${BU_TS_RESULT[pipeAfter]}" "grep tx"
}

# ===========================================================================
# DAEMON OUTPUT: process substitution
# ===========================================================================

function test_ts_procsub_basic { #@test
    # diff <(git d  — cursor on d inside process substitution
    bu_ts_parse 12 'diff <(git d' 2>/dev/null
    assert_equal "${BU_TS_RESULT[cmdName]}" "git"
    # pipeBefore should include <( opener
    [[ "${BU_TS_RESULT[pipeBefore]}" == *"<("* ]]
}

# ===========================================================================
# DAEMON OUTPUT: range-based replacement values
# ===========================================================================

function test_ts_range_dollar_word { #@test
    # echo $HO  — replace bytes 5-8 ($HO)
    bu_ts_parse 8 'echo $HO' 2>/dev/null
    assert_equal "${BU_TS_RESULT[cursor,replaceStart]}" "5"
    assert_equal "${BU_TS_RESULT[cursor,replaceEnd]}"   "8"
    assert_equal "${BU_TS_RESULT[cursor,replaceText]}"  '$HO'
}

function test_ts_range_dollar_in_quotes { #@test
    # echo "$HO  — replace bytes 6-9 ($HO) not including the quote
    bu_ts_parse 9 'echo "$HO' 2>/dev/null
    assert_equal "${BU_TS_RESULT[cursor,replaceStart]}" "6"
    assert_equal "${BU_TS_RESULT[cursor,replaceEnd]}"   "9"
}

function test_ts_range_dollar_brace_in_quotes { #@test
    # echo "${HO  — replace bytes 6-10 (${HO) including brace
    bu_ts_parse 10 'echo "${HO' 2>/dev/null
    assert_equal "${BU_TS_RESULT[cursor,completeKind]}" "dollar_brace"
}

function test_ts_range_cursor_at_end { #@test
    # bu  — cursor at end, range should be [3,3) or [0,0) — both valid
    bu_ts_parse 3 'bu ' 2>/dev/null
    local rs=${BU_TS_RESULT[cursor,replaceStart]}
    local re=${BU_TS_RESULT[cursor,replaceEnd]}
    # Either [0,0) (no node) or [3,3) (cursor offset)
    [[ ( "$rs" = "0" && "$re" = "0" ) || "$rs" = "$re" ]]
}

# ===========================================================================
# END-TO-END: completion dispatch
# ===========================================================================

function test_e2e_command_after_space { #@test
    # bu <TAB> — show bu subcommands
    assert_completions -1 "get-command" "bu " 3
}

function test_e2e_command_partial { #@test
    # bu get-<TAB> — show matching subcommands
    assert_completions 1 "get-command" "bu get-" 7
}

function test_e2e_dollar_variable { #@test
    # echo $HO<TAB> — show $HOME, $HOSTNAME, ...
    assert_completions -1 '$HOME' 'echo $HO' 8
}

function test_e2e_dollar_in_quotes { #@test
    # echo "$HO<TAB> — show $HOME etc
    assert_completions -1 '$HOME' 'echo "$HO' 9
}

function test_e2e_dollar_brace { #@test
    # echo ${HO<TAB> — show ${HOME} etc
    assert_completions -1 '${HOME}' 'echo ${HO' 9
}

function test_e2e_dollar_brace_in_quotes { #@test
    # echo "${HO<TAB>
    assert_completions -1 '${HOME}' 'echo "${HO' 10
}

function test_e2e_prefix_in_quotes { #@test
    # echo "2020-11-$HO<TAB> — only $HO is replaced
    assert_completions -1 '$HOME' 'echo "2020-11-$HO' 17
}

function test_e2e_cmdsub_command { #@test
    # ls $(gre<TAB> — complete command name inside $()
    assert_completions -1 "grep" 'ls $(gre' 8
}

function test_e2e_cmdsub_arg { #@test
    skip "requires git completions in test environment"
    assert_completions -1 "stash" 'ls $(git st' 10
}

function test_e2e_procsub { #@test
    skip "requires git completions in test environment"
    assert_completions -1 "describe" 'diff <(git d' 12
}

# ===========================================================================
# END-TO-END: reconstruction simulation
# ===========================================================================

# Simulate the full fzf selection flow and check the reconstructed line
simulate_selection() {
    local front="$1" back="$2" label="$3"
    local offset=${#front}

    bu_ts_parse "$offset" "$front" 2>/dev/null

    local original=${BU_TS_RESULT[original]}
    local pipe_before=${BU_TS_RESULT[pipeBefore]}
    local kind=${BU_TS_RESULT[cursor,completeKind]}
    local rs=${BU_TS_RESULT[cursor,replaceStart]}
    local re=${BU_TS_RESULT[cursor,replaceEnd]}

    local -a cmd_words=()
    local _saved_ifs=$IFS
    IFS=$'\037'
    cmd_words=(${BU_TS_RESULT[cmdWords]})
    IFS=$_saved_ifs
    if [[ "${original:${#original}-1}" = ' ' ]]; then cmd_words+=(""); fi

    COMPREPLY=()
    local is_range=false
    case "$kind" in
    dollar_word|dollar_brace)
        is_range=true
        local rt=${BU_TS_RESULT[cursor,replaceText]}
        if [[ "$kind" == "dollar_brace" ]]; then
            COMPREPLY=($(compgen -A variable -P '${' -S '}' -- "${rt#\$\{}"))
        else
            COMPREPLY=($(compgen -A variable -P '$' -- "${rt#\$}"))
        fi
        ;;
    *)
        bu_autocomplete_get_autocompletions --accept-ansi-colors "${cmd_words[@]}" 2>/dev/null
        ;;
    esac

    if (( ${#COMPREPLY[@]} == 0 )); then
        echo "NO_COMPLETIONS"
        return
    fi

    local sel="${COMPREPLY[0]}"
    sel=$(sed -r $'s/\x1B\\[[0-9;]*[mGK]//g' <<<"$sel")
    sel=$(sed -r $'s/\x1B\\(B//g' <<<"$sel")

    local result
    if "$is_range"; then
        result="${original:0:rs}${sel}${original:re}${back}"
    else
        cmd_words[-1]=$sel
        local words="${cmd_words[*]}"
        local back_no_op=${back%%[[:space:]]*}
        back_no_op=${back_no_op%%)*}; back_no_op=${back_no_op%%;*}; back_no_op=${back_no_op%%&&*}; back_no_op=${back_no_op%%|*}
        local trimmed_back=${back:${#back_no_op}}
        trimmed_back=${trimmed_back# }
        if [[ "${words:${#words}-1}" != ' ' && "${trimmed_back:0:1}" != ' ' ]]; then words+=' '; fi
        result="${pipe_before}${words}${trimmed_back}"
    fi

    echo "$result"
}

function test_reconstruct_bu { #@test
    local result
    result=$(simulate_selection 'bu ' '' 'bu tab')
    # Should be "bu get-command " (the first completion)
    [[ "$result" == "bu get-command "* ]]
}

function test_reconstruct_dollar { #@test
    local result
    result=$(simulate_selection 'echo $HO' '' 'dollar')
    assert_equal "$result" 'echo $HOME'
}

function test_reconstruct_dollar_in_quotes { #@test
    local result
    result=$(simulate_selection 'echo "$HO' '' 'dollar quoted')
    assert_equal "$result" 'echo "$HOME'
}

function test_reconstruct_prefix_in_quotes { #@test
    local result
    result=$(simulate_selection 'echo "2020-11-$HO' '' 'prefix quoted')
    # Only $HO replaced, prefix preserved
    assert_equal "$result" 'echo "2020-11-$HOME'
}

function test_reconstruct_dollar_brace { #@test
    local result
    result=$(simulate_selection 'echo ${HO' '' 'brace')
    assert_equal "$result" 'echo ${HOME}'
}

function test_reconstruct_cmdsub { #@test
    local result
    result=$(simulate_selection 'ls $(gre' '' 'cmdsub')
    # Should be "ls $(grep" — $( preserved
    [[ "$result" == "ls \$("* ]]
}

function test_reconstruct_pipe { #@test
    local result
    result=$(simulate_selection 'echo $(ls) | gre' '' 'pipe')
    # pipeBefore should include "echo $(ls) | "
    [[ "$result" == "echo \$(ls) | grep "* ]]
}

# ===========================================================================
# END-TO-END: variable completion count sanity
# ===========================================================================

function test_e2e_var_count_dollar { #@test
    assert_completions 3 '$HOME' 'echo $HO' 8
}

function test_e2e_var_count_dollar_brace { #@test
    assert_completions 3 '${HOME}' 'echo ${HO' 9
}

function test_e2e_var_count_quoted { #@test
    assert_completions 3 '$HOME' 'echo "$HO' 9
}
