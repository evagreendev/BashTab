#!/usr/bin/env -S bats --jobs 16

bats_require_minimum_version 1.5.0

# bu_module_require: dependency-free module loader.  Every test executes the
# helper in a bare `bash -euo pipefail` subshell so the `set -e` / `set -u`
# and dependency-free constraints are exercised for real (the helper may not
# call any bu_* function and must not abort the subshell).

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    MODULE_REQUIRE="$DIR/../lib/bu_module_require.sh"
}

# Write a *_bu_module.sh fixture that appends `modname:0.1.0:...;` to
# BU_MODULE_LIST when sourced.  The script filename is independent of the
# module name it registers, exactly like real modules (a repo named one thing
# can register a module named another).
__make_module_script() {
    local dir=$1
    local fname=$2
    local modname=$3
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\nBU_MODULE_LIST+="%s:0.1.0:/fake/%s-preinit.sh;"\n' "$modname" "$modname" > "$dir/$fname"
}

# Run `bu_module_require "$@"` once in a bare `bash -euo pipefail`, reporting
# the rc, the resulting BU_MODULE_LIST, and the number of registry entries.
__mr_run() {
    run --separate-stderr bash -euo pipefail -c '
        source "$1"
        shift
        export BU_MODULE_LIST=
        if bu_module_require "$@"; then
            _rc=0
        else
            _rc=$?
        fi
        printf "rc=%s\n" "$_rc"
        printf "list=%s\n" "${BU_MODULE_LIST:-}"
        IFS=";" read -r -a _parts <<< "${BU_MODULE_LIST:-}" || true
        _n=0
        for _p in "${_parts[@]}"; do
            [[ -n "$_p" ]] && _n=$((_n+1))
        done
        printf "count=%s\n" "$_n"
    ' _ "$MODULE_REQUIRE" "$@"
}

function test_requires_present_module { #@test
    local moddir="$BATS_TEST_TMPDIR/present"
    __make_module_script "$moddir" "moda_bu_module.sh" "moda"

    __mr_run moda --dir "$moddir"

    assert_success
    assert_line "rc=0"
    assert_line "count=1"
    assert_output --partial "moda:0.1.0:"
}

function test_resolves_module_script_with_different_filename_prefix { #@test
    local moddir="$BATS_TEST_TMPDIR/prefix"
    __make_module_script "$moddir" "shelf_bu_module.sh" "gitshelf"

    __mr_run gitshelf --dir "$moddir"

    assert_success
    assert_line "rc=0"
    assert_output --partial "gitshelf:0.1.0:"
}

function test_idempotent_single_registry_entry { #@test
    local moddir="$BATS_TEST_TMPDIR/idem"
    __make_module_script "$moddir" "moda_bu_module.sh" "moda"

    run --separate-stderr bash -euo pipefail -c '
        source "$1"
        export BU_MODULE_LIST=
        if bu_module_require moda --dir "$2"; then
            r1=0
        else
            r1=$?
        fi
        if bu_module_require moda --dir "$2"; then
            r2=0
        else
            r2=$?
        fi
        printf "r1=%s r2=%s\n" "$r1" "$r2"
        printf "list=%s\n" "${BU_MODULE_LIST:-}"
    ' _ "$MODULE_REQUIRE" "$moddir"

    assert_success
    assert_line "r1=0 r2=0"

    local count
    count=$(grep -oF 'moda:0.1.0:' <<< "$output" | wc -l | tr -d ' ')
    assert_equal "$count" "1"
}

function test_anchored_match_suffix_name { #@test
    local moddir="$BATS_TEST_TMPDIR/anchored"
    __make_module_script "$moddir" "lib_bu_module.sh" "lib"

    run --separate-stderr bash -euo pipefail -c '
        source "$1"
        export BU_MODULE_LIST="mylib:0.1.0:/x/mylib-preinit.sh;"
        if bu_module_require lib --dir "$2"; then
            r1=0
        else
            r1=$?
        fi
        printf "r1=%s\n" "$r1"
        printf "list=%s\n" "${BU_MODULE_LIST:-}"
    ' _ "$MODULE_REQUIRE" "$moddir"

    assert_success
    assert_line "r1=0"
    assert_output --partial "mylib:0.1.0:"
    assert_output --partial ";lib:0.1.0:"
}

function test_optional_missing_is_info_rc0 { #@test
    local moddir="$BATS_TEST_TMPDIR/nothere"

    __mr_run optmod --dir "$moddir"

    assert_success
    assert_line "rc=0"
    assert_line "count=0"
    assert_stderr --partial "INFO"
    assert_stderr --partial "skipping"
}

function test_required_missing_rc1 { #@test
    local moddir="$BATS_TEST_TMPDIR/nothere-req"

    __mr_run reqmod --dir "$moddir" --required

    assert_success
    assert_line "rc=1"
    assert_stderr --partial "ERR"
}

function test_ambiguous_glob_errors { #@test
    local moddir="$BATS_TEST_TMPDIR/ambiguous"
    __make_module_script "$moddir" "foo_bu_module.sh" "foo"
    __make_module_script "$moddir" "bar_bu_module.sh" "bar"

    __mr_run moda --dir "$moddir"

    assert_success
    assert_line "rc=0"
    assert_stderr --partial "disambiguate"
    assert_stderr --partial "ERR"

    __mr_run moda --dir "$moddir" --required

    assert_success
    assert_line "rc=1"
    assert_stderr --partial "disambiguate"
}

function test_module_file_overrides_glob { #@test
    local moddir="$BATS_TEST_TMPDIR/modfile"
    __make_module_script "$moddir" "foo_bu_module.sh" "foo"
    __make_module_script "$moddir" "bar_bu_module.sh" "bar"

    __mr_run bar --module-file "$moddir/bar_bu_module.sh"

    assert_success
    assert_line "rc=0"
    assert_output --partial "bar:0.1.0:"
    refute_output --partial "foo:0.1.0:"
}

function test_autoclone_with_branch_registers { #@test
    local repo="$BATS_TEST_TMPDIR/repo"
    local target="$BATS_TEST_TMPDIR/deps/modx"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name Test

    # main branch registers the WRONG name; proving rc=0 below means --branch
    # was honored (a default-branch clone would fail the name check).
    printf '#!/usr/bin/env bash\nBU_MODULE_LIST+="modx_main:0.1.0:/fake/preinit.sh;"\n' > "$repo/modx_bu_module.sh"
    git -C "$repo" add -A
    git -C "$repo" commit -qm "main"
    git -C "$repo" checkout -q -b dev
    printf '#!/usr/bin/env bash\nBU_MODULE_LIST+="modx:0.1.0:/fake/preinit.sh;"\n' > "$repo/modx_bu_module.sh"
    git -C "$repo" add -A
    git -C "$repo" commit -qm "dev"

    __mr_run modx --dir "$target" --git-url "file://$repo" --branch dev --required

    assert_success
    assert_line "rc=0"
    assert_output --partial "modx:0.1.0:"
    refute_output --partial "modx_main"
}

function test_clone_failure_degrades_to_missing_policy { #@test
    local target="$BATS_TEST_TMPDIR/deps/offline"

    __mr_run modx --dir "$target" --git-url "file:///nonexistent/repo"

    assert_success
    assert_line "rc=0"
    assert_stderr --partial "clone"
    assert_stderr --partial "skipping"
}

function test_name_mismatch_warn { #@test
    local moddir="$BATS_TEST_TMPDIR/mismatch"
    __make_module_script "$moddir" "actual_bu_module.sh" "actual"

    __mr_run expected --module-file "$moddir/actual_bu_module.sh"

    assert_success
    assert_line "rc=0"
    assert_stderr --partial "WARN"
    assert_stderr --partial "did not register"
    assert_output --partial "actual:0.1.0:"

    __mr_run expected --module-file "$moddir/actual_bu_module.sh" --required

    assert_success
    assert_line "rc=1"
    assert_stderr --partial "did not register"
}

function test_usage_errors { #@test
    local moddir="$BATS_TEST_TMPDIR/usage"
    __make_module_script "$moddir" "moda_bu_module.sh" "moda"

    # no NAME
    __mr_run
    assert_line "rc=1"
    assert_stderr --partial "missing module NAME"

    # NAME looks like a flag
    __mr_run --required --dir "$moddir"
    assert_line "rc=1"
    assert_stderr --partial "looks like a flag"

    # neither --dir nor --module-file
    __mr_run moda
    assert_line "rc=1"
    assert_stderr --partial "one of --dir or --module-file"

    # unknown option
    __mr_run moda --dir "$moddir" --bogus
    assert_line "rc=1"
    assert_stderr --partial "unknown option"

    # flag missing its value
    __mr_run moda --dir
    assert_line "rc=1"
    assert_stderr --partial "requires a value"
}
