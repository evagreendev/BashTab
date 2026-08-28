#!/usr/bin/env -S bats --jobs 16
#
# Capability probe resolver hook (BU_CAP_MISS_RESOLVER) and site/*.sh glue.
#
# On managed environments (module systems, HPC clusters) a base shell is
# missing fzf/jq/node until a site-specific load command runs.  A site file
# may install a BU_CAP_MISS_RESOLVER function that makes such binaries
# available on demand during probing.  These tests cover the miss path, the
# resolver success/failure paths, and the site/*.sh sourcing contract.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # shellcheck source=../bu_entrypoint.sh
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"
}

teardown() {
    # A test that moved site/ aside (or left a fixture behind) must not leak
    # that state into a parallel test file's activation.
    local site_dir="$DIR/../site"
    rm -f "$site_dir"/zz_bats_site_marker.sh
    local backup="$BATS_TEST_TMPDIR/site-backup"
    if [[ -d "$backup" && ! -d "$site_dir" ]]; then
        mv "$backup" "$site_dir"
    fi
}

function test_cap_probe_miss_without_resolver { #@test
    unset BU_CAP_MISS_RESOLVER
    bu_cap_probe bats_test_cap_no_resolver definitely-not-a-real-binary-xyz
    assert_equal "${BU_CAP[bats_test_cap_no_resolver]:-}" ""
}

function test_cap_probe_resolver_creates_binary_on_demand { #@test
    mkdir -p "$BATS_TEST_TMPDIR/stub-bin"

    # A resolver that manufactures the requested binary in a directory that is
    # already on PATH (the probe re-runs `command -v` after the call).
    __test_make_binary_resolver() {
        local binary=$2
        local dir="$BATS_TEST_TMPDIR/stub-bin"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/$binary"
        chmod +x "$dir/$binary"
    }

    BU_CAP_MISS_RESOLVER=__test_make_binary_resolver
    PATH="$BATS_TEST_TMPDIR/stub-bin:$PATH"

    bu_cap_probe bats_test_cap_resolver some-on-demand-binary-xyz
    assert_equal "${BU_CAP[bats_test_cap_resolver]}" "$BATS_TEST_TMPDIR/stub-bin/some-on-demand-binary-xyz"
}

function test_cap_probe_failing_resolver_leaves_cap_empty { #@test
    __test_failing_resolver() { return 1; }
    BU_CAP_MISS_RESOLVER=__test_failing_resolver

    run bu_cap_probe bats_test_cap_fail definitely-not-a-real-binary-xyz
    assert_success
    assert_equal "${BU_CAP[bats_test_cap_fail]:-}" ""
}

function test_activation_succeeds_with_failing_resolver_under_set_e { #@test
    # A resolver that returns non-zero must not abort activation, even under
    # `set -e` (the probe runs while the entrypoint is being sourced).
    run bash -c '
        set -e
        __test_failing_resolver() { return 1; }
        BU_CAP_MISS_RESOLVER=__test_failing_resolver
        export BU_CAP_MISS_RESOLVER
        source "$1"/bu_entrypoint.sh >/dev/null 2>&1
        # Force at least one resolver invocation after activation to prove the
        # guard holds on the direct path too.
        bu_cap_probe bats_test_cap_forced definitely-not-a-real-binary-xyz
        echo "ACTIVATED cap=${BU_CAP[bats_test_cap_forced]:-EMPTY}"
    ' _ "$DIR"/..
    assert_success
    assert_output --partial "ACTIVATED cap=EMPTY"
}

function test_site_files_are_sourced_at_entrypoint { #@test
    local site_dir="$DIR/../site"
    local fixture="$site_dir/zz_bats_site_marker.sh"
    rm -f "$fixture"

    # Plain assignment: visible as a global even though site files are sourced
    # through the custom source() function.
    printf 'BATS_SITE_SOURCED_MARKER=yes\n' > "$fixture"

    run bash -c 'source "$1"/bu_entrypoint.sh >/dev/null 2>&1; printf "%s" "${BATS_SITE_SOURCED_MARKER:-unset}"' _ "$DIR"/..
    rm -f "$fixture"

    assert_success
    assert_output "yes"
}

function test_missing_site_dir_is_silent { #@test
    local site_dir="$DIR/../site"
    local backup="$BATS_TEST_TMPDIR/site-backup"
    rm -rf "$backup"
    mv "$site_dir" "$backup"

    run bash -c 'source "$1"/bu_entrypoint.sh >/dev/null 2>&1; echo ACTIVATED' _ "$DIR"/..

    mv "$backup" "$site_dir"

    assert_success
    assert_output "ACTIVATED"
}
