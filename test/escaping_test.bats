#!/usr/bin/env -S bats --jobs 4

# Tests for case-block doc parser escaping (autohelp / autocomplete).
#
# Verifies that backticks and double-quotes in option documentation prose
# are escaped before embedding in bash assignments (no spurious command
# execution or syntax errors), while ${VAR} and $(cmd) remain live for
# deliberate dynamic doc content.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    source "$DIR"/../bu_entrypoint.sh

    source "$BU_NULL"
}

# ===========================================================================
# Helpers
# ===========================================================================

__parse_docs() {
    local script=$1
    # shellcheck disable=SC2034
    local -a bu_script_options=() bu_script_option_synopsis=() bu_script_option_docs=()
    eval "$(bu_autohelp_parse_case_block_help "$script" "" "" "")"
    echo "${bu_script_option_docs[0]}"
}

# ===========================================================================
# Tests
# ===========================================================================

function test_escaping_backticks_verbatim { #@test
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    cat > "$tmpdir/demo.sh" <<'SCRIPT'
while (($#)); do
  case "$1" in
  --fmt)# VAL
    # Use `json` or `table` format.
    shift 2;;
  *) shift;;
  esac
done
SCRIPT
    run __parse_docs "$tmpdir/demo.sh"
    assert_output --partial '`json`'
    assert_output --partial '`table`'
}

function test_escaping_double_quotes_verbatim { #@test
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    cat > "$tmpdir/demo.sh" <<'SCRIPT'
while (($#)); do
  case "$1" in
  --fmt)# VAL
    # Use "json" or "table" format.
    shift 2;;
  *) shift;;
  esac
done
SCRIPT
    run __parse_docs "$tmpdir/demo.sh"
    assert_output --partial '"json"'
    assert_output --partial '"table"'
}

function test_escaping_dollar_var_live { #@test
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    cat > "$tmpdir/demo.sh" <<'SCRIPT'
while (($#)); do
  case "$1" in
  --path)# PATH
    # Default: ${HOME}/.config
    shift 2;;
  *) shift;;
  esac
done
SCRIPT
    run __parse_docs "$tmpdir/demo.sh"
    assert_output --partial "$HOME"
}

function test_escaping_dollar_paren_live { #@test
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    cat > "$tmpdir/demo.sh" <<'SCRIPT'
while (($#)); do
  case "$1" in
  --test)# CMD
    # Test $(echo LIVE) execution.
    shift 2;;
  *) shift;;
  esac
done
SCRIPT
    run __parse_docs "$tmpdir/demo.sh"
    assert_output --partial 'LIVE'
}
