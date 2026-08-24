#!/usr/bin/env -S bats --jobs 16

# Unit tests for the named location registry (lib/core/bu_core_location.sh)
# and repo registry (lib/core/bu_core_repo.sh), plus their CLI surface.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # Isolate user-local location persistence per test.
    export BU_LOCATION_LOCAL_FILE="$BATS_TEST_TMPDIR/bu_locations_local.sh"
    rm -f "$BU_LOCATION_LOCAL_FILE"
    # shellcheck source=../bu_entrypoint.sh
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"
}

# ===========================================================================
# bu_location_register / bu_location_resolve
# ===========================================================================

function test_location_register_resolve_path { #@test
    local out
    bu_location_register myloc --path /tmp --alias ml
    bu_location_resolve ml
    assert_equal "${BU_RET[0]}" /tmp
}

function test_location_lazy_reexpansion { #@test
    local out
    export MYLOCDIR=/tmp
    bu_location_register lazy --path '$MYLOCDIR/build'
    export MYLOCDIR=/etc
    bu_location_resolve lazy --no-verify
    assert_equal "${BU_RET[0]}" /etc/build
}

function test_location_path_with_spaces_single_element { #@test
    local out
    mkdir -p "/tmp/bu loc space"
    bu_location_register spaced --path '/tmp/bu loc space'
    bu_location_resolve spaced
    assert_equal "${BU_RET[0]}" "/tmp/bu loc space"
    assert_equal "${#BU_RET[@]}" 1
}

function test_location_register_rejects_command_substitution { #@test
    run bu_location_register bad --path '$(touch /tmp/pwned)'
    assert_failure
    run bu_location_register bad --path 'x`echo hi`y'
    assert_failure
    run bu_location_register bad --path 'a; rm -rf /'
    assert_failure
}

function test_location_resolve_kind_mismatch_and_unknown { #@test
    bu_location_register fl --kind file --path /etc/hosts
    run bu_location_resolve fl --kind dir
    assert_failure
    run bu_location_resolve nosuch
    assert_failure
}

function test_location_resolve_missing_dir_verify { #@test
    bu_location_register missing --path /tmp/definitely-not-here-xyz
    run bu_location_resolve missing
    assert_failure
    bu_location_resolve missing --no-verify
    assert_equal "${BU_RET[0]}" /tmp/definitely-not-here-xyz
}

function test_location_multi_resolver_array { #@test
    multi_resolver() { BU_RET=(alpha beta gamma); }
    bu_location_register mm --kind multi --resolver multi_resolver
    bu_location_resolve mm
    assert_equal "${BU_RET[*]}" "alpha beta gamma"
}

function test_location_register_overwrite_clears_stale { #@test
    multi_resolver() { BU_RET=(x); }
    bu_location_register ow --kind dir --resolver multi_resolver --alias ow1 --description old --on-enter hookfn
    bu_location_register ow --kind dir --path /tmp
    assert_equal "${BU_LOCATION_PROPERTIES[ow,resolver]:-}" ""
    assert_equal "${BU_LOCATION_PROPERTIES[ow,description]:-}" ""
    assert_equal "${BU_LOCATION_PROPERTIES[ow,on_enter]:-}" ""
    assert_equal "${BU_LOCATION_ALIASES[ow1]:-}" ""
}

function test_location_names_filters { #@test
    local out
    bu_location_register tagged --path /tmp --tags work,important --alias tg
    bu_location_register fl --kind file --path /etc/hosts

    out=$(bu_location_names --tag important)
    assert_equal "$out" tagged
    out=$(bu_location_names --kind file)
    assert_equal "$out" fl
    out=$(bu_location_names --kind dir --with-aliases | grep -x tg)
    assert_equal "$out" tg
}

function test_location_names_tolerates_stray_words { #@test
    # The completion-feed contract: `--stdout bu_location_names ...` appends
    # the in-progress word ('' / '--' / a partial token). These must be
    # ignored without erroring and without breaking the listing.
    local out
    bu_location_register tagged --path /tmp --tags work,important --alias tg
    bu_location_register fl --kind file --path /etc/hosts

    run bu_location_names --kind dir --
    assert_success
    assert_output --partial tagged

    run bu_location_names --kind dir ''
    assert_success
    assert_output --partial tagged

    run bu_location_names --kind dir ta
    assert_success
    assert_output --partial tagged
}

function test_location_canonical_name_contract { #@test
    bu_location_register canon --path /tmp --alias al

    local rc
    # Alias maps to canonical
    bu_location_canonical_name al
    rc=$?
    assert_equal "$rc" 0
    assert_equal "$BU_RET" canon

    # Canonical maps to itself
    bu_location_canonical_name canon
    rc=$?
    assert_equal "$rc" 0
    assert_equal "$BU_RET" canon

    # Unregistered name maps to itself, rc=0 (no unknown-location error)
    bu_location_canonical_name nosuch
    rc=$?
    assert_equal "$rc" 0
    assert_equal "$BU_RET" nosuch
}

function test_location_register_on_enter_non_dir_rejected { #@test
    run bu_location_register fl --kind file --path /etc/hosts --on-enter myhook
    assert_failure
}

# ===========================================================================
# bu_location_enter (goto primitive)
# ===========================================================================

function test_location_enter_cd_and_on_enter { #@test
    local hook_args=
    myhook() { hook_args="$1:$2"; export HOOK_ENV_SURVIVES=yes; }
    bu_location_register hloc --path /tmp --on-enter myhook
    cd /
    bu_location_enter hloc
    assert_equal "$PWD" /tmp
    assert_equal "$hook_args" "hloc:/tmp"
    assert_equal "${HOOK_ENV_SURVIVES:-}" yes
}

function test_location_enter_failing_hook_keeps_cd { #@test
    failing_hook() { return 1; }
    bu_location_register floc --path /tmp --on-enter failing_hook
    cd /
    bu_location_enter floc
    assert_equal "$PWD" /tmp
}

function test_location_enter_no_enter_hook_skips { #@test
    local called=no
    myhook() { called=yes; }
    bu_location_register nloc --path /tmp --on-enter myhook
    cd /
    bu_location_enter nloc --no-enter-hook
    assert_equal "$PWD" /tmp
    assert_equal "$called" no
}

# ===========================================================================
# CLI: set-location / push-location / get-location-registry
# ===========================================================================

function test_set_location_named_cd { #@test
    bu_location_register jump --path /tmp
    cd /
    bu set-location jump
    assert_equal "$PWD" /tmp
}

function test_set_location_dry_run_record { #@test
    bu_location_register jump --path /tmp --on-enter myhook
    local out
    out=$(bu set-location jump --dry-run 2>/dev/null)
    assert_equal "$out" '{"name":"jump","path":"/tmp","on_enter":"myhook","action":"would-cd","dry_run":true}'
}

function test_push_location_registry_vs_literal { #@test
    mkdir -p /tmp/realname /tmp/otherdir
    bu_location_register realname --path /tmp/otherdir

    # From /tmp, ./realname is a real directory → literal wins.
    cd /tmp
    bu push-location realname >/dev/null
    assert_equal "$PWD" /tmp/realname
    bu pop-location >/dev/null

    # From /, ./realname does not exist → registry resolves.
    cd /
    bu push-location realname >/dev/null
    assert_equal "$PWD" /tmp/otherdir
    bu pop-location >/dev/null
}

function test_get_location_registry_records_and_filters { #@test
    bu_location_register src --path /tmp --alias s --description 'src' --tags work
    bu_location_register fl --kind file --path /etc/hosts --tags cfg

    local out
    out=$(bu get-location-registry --format jsonl | jq -c 'select(.name == "src") | del(.source)')
    assert_equal "$out" '{"name":"src","kind":"dir","path_expr":"/tmp","resolved":"/tmp","description":"src","tags":"work","aliases":"s","on_enter":""}'

    # Provenance is recorded (actual registrant file).
    out=$(bu get-location-registry --format jsonl | jq -r 'select(.name == "src") | .source')
    [[ -n "$out" ]]

    out=$(bu get-location-registry --tag cfg --format jsonl | jq -r .name)
    assert_equal "$out" fl
}

function test_get_location_registry_survives_broken_resolver { #@test
    broken_resolver() { return 1; }
    bu_location_register br --resolver broken_resolver
    local out
    out=$(bu get-location-registry --format jsonl)
    assert_equal "$(printf '%s' "$out" | jq -r .resolved)" ""
}

# ===========================================================================
# CLI: new-location (persistence)
# ===========================================================================

function test_new_location_persist_and_resolve { #@test
    mkdir -p /tmp/projdir
    export PROJROOT=/tmp/projdir
    bu new-location myproj --path '$PROJROOT' --alias mp --description 'proj' >/dev/null 2>&1

    # Immediate availability
    bu_location_resolve mp
    assert_equal "${BU_RET[0]}" /tmp/projdir

    # Wipe the registry arrays and re-source the local file.
    declare -A -g BU_LOCATION_REGISTRY=()
    declare -A -g BU_LOCATION_PROPERTIES=()
    declare -A -g BU_LOCATION_ALIASES=()
    bu_location_source_local_file

    bu_location_resolve myproj
    assert_equal "${BU_RET[0]}" /tmp/projdir

    # The lazy expression stays unexpanded in the file (literal $PROJROOT).
    grep -q '\$PROJROOT' "$BU_LOCATION_LOCAL_FILE"
}

function test_new_location_same_name_single_line { #@test
    bu new-location foo --path /tmp --alias f1 >/dev/null 2>&1
    bu new-location foo --path /tmp --alias f2 >/dev/null 2>&1
    assert_equal "$(grep -c 'bu_location_register foo' "$BU_LOCATION_LOCAL_FILE")" 1
}

function test_new_location_remove { #@test
    bu new-location foo --path /tmp >/dev/null 2>&1
    bu new-location --remove foo >/dev/null 2>&1
    assert_equal "$(grep -c 'bu_location_register foo' "$BU_LOCATION_LOCAL_FILE" || true)" 0
    run bu_location_resolve foo
    assert_failure
}

function test_new_location_degenerate_block_refused { #@test
    cat > "$BU_LOCATION_LOCAL_FILE" <<'EOF'
# >>> bu new-location managed block -- do not hand-edit inside
# >>> bu new-location managed block -- do not hand-edit inside
bu_location_register zz --path /tmp
# <<< bu new-location managed block
EOF
    local before
    before=$(cat "$BU_LOCATION_LOCAL_FILE")
    run bu new-location zz2 --path /tmp
    assert_failure
    assert_equal "$(cat "$BU_LOCATION_LOCAL_FILE")" "$before"
}

function test_new_location_repo_persists_repo_register { #@test
    bu new-location myrepo --path /tmp --repo --gh-slug acme/widget >/dev/null 2>&1
    grep -q 'bu_repo_register myrepo' "$BU_LOCATION_LOCAL_FILE"
    bu_repo_resolve_slug myrepo
    assert_equal "$BU_RET" acme/widget
}

# ===========================================================================
# Repo registry
# ===========================================================================

function test_repo_tag_and_resolve_non_worktree { #@test
    mkdir -p /tmp/notrepo
    bu_repo_register nr --path /tmp/notrepo
    assert_equal "$(bu_repo_names | grep -x nr)" nr
    run bu_repo_resolve nr
    assert_failure
}

function test_repo_register_rejects_kind { #@test
    run bu_repo_register rr --kind file --path /tmp
    assert_failure
}

function test_repo_parse_remote_url_forms { #@test
    bu_repo_parse_remote_url 'git@github.com:owner/repo.git'
    assert_equal "$BU_RET" owner/repo
    assert_equal "${BU_RET_MAP[host]}" github.com

    bu_repo_parse_remote_url 'https://github.com/owner/repo'
    assert_equal "$BU_RET" owner/repo
    assert_equal "${BU_RET_MAP[host]}" github.com

    bu_repo_parse_remote_url 'ssh://git@github.com:22/owner/repo.git'
    assert_equal "$BU_RET" owner/repo
    assert_equal "${BU_RET_MAP[host]}" github.com
}

function test_repo_parse_remote_url_bare_path_fails { #@test
    run bu_repo_parse_remote_url 'owner/repo'
    assert_failure
}

function test_repo_resolve_slug_registered_beats_derivation { #@test
    rm -rf /tmp/slugrepo
    mkdir -p /tmp/slugrepo
    git -C /tmp/slugrepo init -q 2>/dev/null
    git -C /tmp/slugrepo remote add origin https://github.com/derived/host.git 2>/dev/null
    bu_repo_register sr --path /tmp/slugrepo --gh-slug reg/istered --gh-host gh.custom.example
    bu_repo_resolve_slug sr
    assert_equal "$BU_RET" reg/istered
    assert_equal "${BU_RET_MAP[host]}" gh.custom.example
}

function test_repo_resolve_slug_derivation_caches { #@test
    rm -rf /tmp/derslug
    mkdir -p /tmp/derslug
    git -C /tmp/derslug init -q 2>/dev/null
    git -C /tmp/derslug remote add origin git@github.com:acme/widget.git 2>/dev/null
    bu_repo_register ds --path /tmp/derslug
    bu_repo_resolve_slug ds
    assert_equal "$BU_RET" acme/widget
    assert_equal "${BU_RET_MAP[host]}" github.com
    assert_equal "${BU_LOCATION_PROPERTIES[ds,repo_gh_slug_cached]:-}" acme/widget
}

function test_get_repo_typed_fields { #@test
    rm -rf /tmp/typedrepo
    mkdir -p /tmp/typedrepo
    git -C /tmp/typedrepo init -q 2>/dev/null
    git -C /tmp/typedrepo remote add origin https://github.com/acme/zeta.git 2>/dev/null
    bu_repo_register tr --path /tmp/typedrepo

    local out
    out=$(bu get-repo tr --format jsonl)
    assert_equal "$(printf '%s' "$out" | jq -c '{exists,is_repo,dirty,gh_slug,gh_host,remote_url}')" \
        '{"exists":true,"is_repo":true,"dirty":false,"gh_slug":"acme/zeta","gh_host":"github.com","remote_url":"https://github.com/acme/zeta.git"}'
}

function test_get_repo_missing_path_graceful { #@test
    bu_repo_register gone --path /tmp/no-such-repo-dir
    local out
    out=$(bu get-repo gone --format jsonl)
    assert_equal "$(printf '%s' "$out" | jq -c '{exists,is_repo,ahead,behind}')" \
        '{"exists":false,"is_repo":false,"ahead":null,"behind":null}'
}
