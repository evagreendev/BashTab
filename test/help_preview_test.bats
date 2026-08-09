#!/usr/bin/env -S bats --jobs 4

# Integration tests for the help-enrich preview pipeline: verify that
# completing options for external commands produces correct descriptions
# in BU_COMPREPLY_METADATA — exercising the actual completion functions.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    source "$DIR"/../bu_entrypoint.sh
    source "$BU_NULL"

    rm -rf "${BU_CACHE_DIR}/help-parse" 2>/dev/null || true
}

# Helper: run completion + enrichment, return candidate -> description map.
_run_pipeline() {
    local prefix=$1; shift
    local -a cmdline=("$@" "$prefix")
    local command_line=("${cmdline[@]}")

    COMPREPLY=()
    BU_COMPREPLY_METADATA=()
    BU_RET_MAP=()

    bu_autocomplete_get_autocompletions --accept-ansi-colors "${cmdline[@]}" 2>/dev/null || true
    if bu_symbol_is_function __bu_help_enrich_preview; then
        __bu_help_enrich_preview COMPREPLY BU_COMPREPLY_METADATA "${cmdline[@]}" 2>/dev/null || true
    fi

    declare -A -g _RESULTS=()
    local i clean
    for ((i = 0; i < ${#COMPREPLY[@]}; i++)); do
        clean=$(sed -r 's/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g' <<<"${BU_COMPREPLY_METADATA[$i]}")
        _RESULTS[${COMPREPLY[$i]}]=$clean
    done
}

# ── git top-level: --no-pager has pager description, not exec-path ──
function test_git_no_pager_not_exec_path { #@test
    _run_pipeline -- git
    local np="${_RESULTS[--no-pager]:-}"
    local ep="${_RESULTS[--exec-path]:-}"
    assert [ -n "$np" ]
    assert [ -n "$ep" ]
    refute [ "$np" = "$ep" ]
    [[ "$np" == *"pager"* || "$np" == *"Pager"* || "$np" == *"pipe"* ]]
    [[ "$ep" == *"EXEC_PATH"* || "$ep" == *"exec-path"* || "$ep" == *"core"* ]]
}

# ── git: exact match for a partially-typed option ──
function test_git_partial_prefix { #@test
    _run_pipeline --no- git
    local desc="${_RESULTS[--no-pager]:-}"
    assert [ -n "$desc" ]
    [[ "$desc" == *"pager"* || "$desc" == *"Pager"* || "$desc" == *"pipe"* ]]
}

# ── ls: --all is about dotfiles, not color ──
function test_ls_all_not_color { #@test
    _run_pipeline -- ls
    local desc="${_RESULTS[--all]:-}"
    assert [ -n "$desc" ]
    refute [[ "$desc" == *"colored escape"* ]]
    refute [[ "$desc" == *"Output colored"* ]]
    [[ "$desc" == *"ignore"* || "$desc" == *"dot"* || "$desc" == *"entries"* ]]
}

# ── ls: --color has color description ──
function test_ls_color { #@test
    _run_pipeline -- ls
    local desc="${_RESULTS[--color]:-}"
    assert [ -n "$desc" ]
    [[ "$desc" == *"color"* || "$desc" == *"Color"* ]]
}
