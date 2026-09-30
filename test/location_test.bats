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
    assert_equal "$out" '{"name":"src","kind":"dir","path_expr":"/tmp","resolved":"/tmp","description":"src","tags":"work","aliases":"s","on_enter":"","param":""}'

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

# Parameterized families: keep values live and never enumerate in bare mode.
function test_location_param_resolution_and_hook { #@test
    local args= hook_args=
    family_complete() { BU_RET=(v 'x@y'); }
    family_resolve() { args="$1:$2"; BU_RET=(/tmp); }
    family_hook() { hook_args="$1:$2"; }
    bu_location_register fam --path / --alias al --param-complete family_complete --param-resolve family_resolve --param-hint item --on-enter family_hook
    __bu_location_resolve_key al@x@y
    assert_equal "$BU_RET" fam
    assert_equal "${BU_RET_MAP[param]}" x@y
    __bu_location_resolve_key fam@
    assert_equal "${BU_RET_MAP[param]}" ''
    bu_location_resolve fam
    assert_equal "$BU_RET" /
    bu_location_resolve al@x@y
    assert_equal "$args" 'fam:x@y'
    assert_equal "$BU_RET" /tmp
    bu_location_resolve fam@v
    assert_equal "$args" fam:v
    bu_location_enter al@v
    assert_equal "$PWD" /tmp
    assert_equal "$hook_args" al@v:/tmp
    bu_location_canonical_name al@v
    assert_equal "$BU_RET" fam
    bu_location_canonical_name @x
    assert_equal "$BU_RET" @x
}

function test_location_param_errors_and_validation { #@test
    family_complete() { BU_RET=(v); }
    family_resolve() { BU_RET=(/tmp); }
    bu_location_register fam --param-complete family_complete --param-resolve family_resolve --param-hint item
    local name
    for name in fam fam@; do
        run bu_location_resolve "$name"
        assert_failure
        assert_output --partial 'location[fam] needs a parameter: fam@<item>'
    done
    bu_location_register plain --path /tmp
    run bu_location_resolve plain@v
    assert_failure
    assert_output --partial 'location[plain] takes no parameter (given [plain@v])'
    for name in 'unknown@v' '@' '@x'; do
        run bu_location_resolve "$name"
        assert_failure
        assert_output --partial "Unknown location[$name]"
        refute_output --partial 'bad array subscript'
    done
    run bu_location_register bad --kind file --param-complete family_complete --param-resolve family_resolve
    assert_failure
    run bu_location_register bad --path /tmp --param-complete family_complete
    assert_failure
    run bu_location_register bad --param-resolve family_resolve
    assert_failure
    run bu_location_register bad --path /tmp --resolver family_resolve
    assert_failure
    run bu_location_register bad
    assert_failure
    run bu_location_register 'a@b' --path /tmp
    assert_failure
    run bu_location_register good --path /tmp --alias 'a@b'
    assert_failure
    bu_location_register fam --path /tmp
    assert_equal "${BU_LOCATION_PROPERTIES[fam,param_complete]:-}" ''
    assert_equal "${BU_LOCATION_PROPERTIES[fam,param_resolve]:-}" ''
    assert_equal "${BU_LOCATION_PROPERTIES[fam,param_hint]:-}" ''
}

function test_location_param_completion_modes { #@test
    family_complete() { [[ "$1" == fam || "$1" == only ]]; BU_RET=(v 'x@y'); }
    family_resolve() { BU_RET=(/tmp); }
    bu_location_register fam --path /tmp --alias al --tags family --param-complete family_complete --param-resolve family_resolve
    bu_location_register only --tags family --alias ol --param-complete family_complete --param-resolve family_resolve
    bu_location_register plain --path /tmp
    run bu_location_names --tag family --with-aliases
    assert_success
    assert_output $'al\nal@\nfam\nfam@\nol@\nonly@'
    run bu_location_names --tag family --with-aliases --no-stubs
    assert_output $'al\nfam'
    run bu_location_names al@part
    assert_output $'al@v\nal@x@y'
    run bu_location_names only@
    assert_output $'only@v\nonly@x@y'
    local word
    for word in plain@ unknown@ @ @x; do
        run bu_location_names "$word"
        assert_success
        assert_output ''
    done
    run bu_location_names --kind file fam@
    assert_output ''
    run bu_location_names --tag other fam@
    assert_output ''
    run bu_location_names --kind file
    refute_output --partial fam
}

function test_repo_param_worktrees_live { #@test
    local root="$BATS_TEST_TMPDIR/repos" value
    mkdir -p "$root/project"
    root=$(cd "$root" && pwd -P)
    git -C "$root/project" init -q
    git -C "$root/project" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm initial
    bu_repo_register repo --path "$root/project"
    git -C "$root/project" worktree add -q "$root/project-worktree-foo" -b feat/x
    git -C "$root/project" worktree add -q "$root/plain" -b other
    run bu_location_names repo@
    assert_success
    assert_equal "$(printf '%s\n' "$output" | sort)" $'repo@foo\nrepo@plain'
    for value in foo project-worktree-foo feat/x; do
        bu_location_resolve "repo@$value"
        assert_equal "$BU_RET" "$root/project-worktree-foo"
    done
    bu_location_resolve repo@plain
    assert_equal "$BU_RET" "$root/plain"
    run bu_location_resolve repo@nope
    assert_failure
    assert_output --partial 'repo[repo] has no worktree[nope]; available:'
    assert_output --partial foo
    assert_output --partial plain
    bu_repo_register secondary --path "$root/project-worktree-foo"
    run bu_location_names secondary@
    assert_equal "$(printf '%s\n' "$output" | sort)" $'secondary@plain\nsecondary@project'
    bu set-location repo@feat/x
    assert_equal "$PWD" "$root/project-worktree-foo"
    run bu_location_names --tag repo
    assert_output $'repo\nrepo@\nsecondary\nsecondary@'
    run bu_repo_names
    assert_output $'repo\nsecondary'
    mkdir "$root/notgit"
    bu_repo_register nongit --path "$root/notgit"
    run bu_location_resolve nongit@v
    assert_failure
    assert_output --partial 'not a git repo'
}

function test_location_param_registry_rows_and_repo_override { #@test
    family_complete() { BU_RET=(v); }
    family_resolve() { BU_RET=(/tmp); }
    bu_location_register only --param-complete family_complete --param-resolve family_resolve --param-hint item
    local out
    out=$(bu get-location-registry --format jsonl)
    assert_equal "$(printf '%s' "$out" | jq -c '{param,resolved}')" '{"param":"item","resolved":"-"}'
    bu_repo_register custom --path /tmp --param-complete family_complete --param-resolve family_resolve --param-hint custom
    assert_equal "${BU_LOCATION_PROPERTIES[custom,param_complete]}" family_complete
    bu_repo_register base --path /tmp --param-hint disabled
    assert_equal "${BU_LOCATION_PROPERTIES[base,param_resolve]}" ''
}

function test_location_param_register_and_resolve { #@test
    local seen_key=
    fam_complete() { BU_RET=(alpha beta); }
    fam_resolve()  { seen_key=$1; BU_RET=("$BATS_TEST_TMPDIR/famdir-$2"); }
    mkdir -p "$BATS_TEST_TMPDIR"/famdir-alpha
    bu_location_register fam --path /tmp --alias fa \
        --param-complete fam_complete --param-resolve fam_resolve --param-hint variant
    assert_equal "${BU_LOCATION_PROPERTIES[fam,param_complete]}" fam_complete
    assert_equal "${BU_LOCATION_PROPERTIES[fam,param_resolve]}" fam_resolve
    assert_equal "${BU_LOCATION_PROPERTIES[fam,param_hint]}" variant

    # bare name still resolves the base target
    bu_location_resolve fam
    assert_equal "${BU_RET[0]}" /tmp

    # head@value goes through the param resolver with (key, value)
    bu_location_resolve fam@alpha
    assert_equal "${BU_RET[0]}" "$BATS_TEST_TMPDIR/famdir-alpha"
    assert_equal "$seen_key" fam

    # alias head
    bu_location_resolve fa@alpha --kind dir
    assert_equal "${BU_RET[0]}" "$BATS_TEST_TMPDIR/famdir-alpha"

    # resolved dir is still verified
    run bu_location_resolve fam@beta
    assert_failure
    assert_output --partial 'directory missing'

    # canonical name strips the param
    bu_location_canonical_name fa@alpha
    assert_equal "$BU_RET" fam

    # value may itself contain '@' (split is at the FIRST '@' only)
    mkdir -p "$BATS_TEST_TMPDIR"/famdir-a@b
    bu_location_resolve fam@a@b
    assert_equal "${BU_RET[0]}" "$BATS_TEST_TMPDIR/famdir-a@b"
}

function test_location_param_empty_head { #@test
    run bu_location_names --kind dir '@'
    assert_success
    assert_output ''
    run bu_location_names --kind dir '@x'
    assert_success
    assert_output ''
    run bu_location_resolve '@x'
    assert_failure
    assert_output --partial 'Unknown location[@x]'
    refute_output --partial 'bad array subscript'
    bu_location_canonical_name '@x'
    assert_equal "$BU_RET" '@x'
}

function test_location_param_only_family { #@test
    po_complete() { BU_RET=(x y); }
    po_resolve()  { BU_RET=("$BATS_TEST_TMPDIR/po-$2"); }
    mkdir -p "$BATS_TEST_TMPDIR"/po-x
    bu_location_register po --param-complete po_complete --param-resolve po_resolve \
        --param-hint thing
    assert_equal "${BU_LOCATION_REGISTRY[po]}" dir

    bu_location_resolve po@x
    assert_equal "${BU_RET[0]}" "$BATS_TEST_TMPDIR/po-x"

    run bu_location_resolve po
    assert_failure
    assert_output --partial 'location[po] needs a parameter: po@<thing>'

    # empty value counts as no value
    run bu_location_resolve po@
    assert_failure
    assert_output --partial 'needs a parameter'
}

function test_location_param_errors { #@test
    bu_location_register plainloc --path /tmp
    run bu_location_resolve plainloc@x
    assert_failure
    assert_output --partial 'location[plainloc] takes no parameter'

    run bu_location_resolve nosuchfam@x
    assert_failure
    assert_output --partial 'Unknown location[nosuchfam@x]'
}

function test_location_param_register_validation { #@test
    vc() { BU_RET=(); }
    vr() { BU_RET=(/tmp); }
    # param options are dir-only
    run bu_location_register bad1 --kind file --path /etc/hosts --param-complete vc \
        --param-resolve vr
    assert_failure
    # the pair must come together
    run bu_location_register bad2 --path /tmp --param-complete vc
    assert_failure
    run bu_location_register bad3 --path /tmp --param-resolve vr
    assert_failure
    # neither base target nor param pair
    run bu_location_register bad4
    assert_failure
    # --path and --resolver still mutually exclusive
    run bu_location_register bad5 --path /tmp --resolver vr --param-complete vc \
        --param-resolve vr
    assert_failure
    # [~2 lines cut off between photos: the positive case \u2014 a param pair
    #  alongside a base target is accepted, e.g.
    #  bu_location_register okfam --path /tmp --param-complete vc --param-resolve vr
    #  assert_equal "${BU_LOCATION_PROPERTIES[okfam,param_complete]}" vc]

    # '@' is reserved in a NAME (would be a silently unreachable entry)
    run bu_location_register 'a@b' --path /tmp
    assert_failure
    assert_output --partial 'cannot contain @'    # adapted to the existing message text
    # ...and in an --alias value
    run bu_location_register okname --path /tmp --alias 'x@y'
    assert_failure
}

function test_location_param_overwrite_clears { #@test
    oc() { BU_RET=(); }
    orr() { BU_RET=(/tmp); }
    bu_location_register ow2 --path /tmp --param-complete oc --param-resolve orr \
        --param-hint h
    bu_location_register ow2 --path /tmp
    assert_equal "${BU_LOCATION_PROPERTIES[ow2,param_complete]:-}" ""
    assert_equal "${BU_LOCATION_PROPERTIES[ow2,param_resolve]:-}" ""
    assert_equal "${BU_LOCATION_PROPERTIES[ow2,param_hint]:-}" ""
    # now a plain entry: a value is an error again
    run bu_location_resolve ow2@x
    assert_failure
}

function test_location_enter_param { #@test
    local hook_args=
    ph() { hook_args="$1:$2"; }
    pc() { BU_RET=(one); }
    pr() { BU_RET=("$BATS_TEST_TMPDIR/wt-$2"); }
    mkdir -p "$BATS_TEST_TMPDIR"/wt-one
    bu_location_register pe --path /tmp --param-complete pc --param-resolve pr --on-enter ph
    cd /
    bu_location_enter pe@one
    assert_equal "$PWD" "$BATS_TEST_TMPDIR/wt-one"
    # hook receives the name AS TYPED and the resolved dir
    assert_equal "$hook_args" "pe@one:$BATS_TEST_TMPDIR/wt-one"
}

function test_location_names_param_modes { #@test
    nc() { BU_RET=(v1 v2); }
    nr() { BU_RET=(/tmp); }
    bu_location_register nfam --path /tmp --alias nf --param-complete nc --param-resolve nr \
        --tags fam
    bu_location_register nonly --param-complete nc --param-resolve nr
    bu_location_register nplain --path /tmp

    # bare mode: static names plus one stub per family; param-only bare name absent
    run bu_location_names --kind dir ''
    assert_success
    assert_line nfam
    assert_line 'nfam@'
    assert_line 'nonly@'
    assert_line nplain
    refute_line nonly

    run bu_location_names --kind dir --with-aliases ''
    assert_line nf
    assert_line 'nf@'

    # @ mode: only that family's values, typed head spelling preserved
    run bu_location_names --kind dir 'nfam@'
    assert_success
    assert_output $'nfam@v1\nnfam@v2'
    run bu_location_names --kind dir 'nf@v'
    assert_output $'nf@v1\nnf@v2'

    # plain entry / unknown head \u2192 nothing, never an error
    run bu_location_names --kind dir 'nplain@'
    assert_success
    assert_output ''
    run bu_location_names --kind dir 'nosuch@'
    assert_success
    assert_output ''

    # kind/tag filters apply to the family
    run bu_location_names --tag fam 'nfam@'
    assert_line 'nfam@v1'
    run bu_location_names --tag other 'nfam@'
    assert_output ''
    run bu_location_names --kind file 'nfam@'
    assert_output ''
}

function test_get_location_registry_param_family_rows { #@test
    gc() { BU_RET=(a); }
    gr() { BU_RET=(/tmp); }
    bu_location_register gfam --path /tmp --param-complete gc --param-resolve gr \
        --param-hint variant
    bu_location_register gonly --param-complete gc --param-resolve gr --param-hint thing
    local out
    out=$(bu get-location-registry --format jsonl | jq -c 'select(.name == "gfam") | {resolved, param}')
    assert_equal "$out" '{"resolved":"/tmp","param":"variant"}'
    out=$(bu get-location-registry --format jsonl | jq -c 'select(.name == "gonly") | {resolved, param}')
    assert_equal "$out" '{"resolved":"-","param":"thing"}'
}

function test_repo_names_no_stubs { #@test
    bu_repo_register rn1 --path /tmp
    run bu_repo_names
    assert_line rn1
    refute_line 'rn1@'
    run bu_location_names --tag repo
    assert_line 'rn1@'
    run bu_location_names --tag repo --no-stubs ''
    refute_line 'rn1@'
}

function test_repo_worktree_family_primary_only { #@test
    local base=$BATS_TEST_TMPDIR/solo
    git init -q "$base"
    git -C "$base" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
    bu_repo_register solo --path "$base"
    __bu_repo_worktree_complete solo
    assert_equal "${#BU_RET[@]}" 0
    run bu_location_names --kind dir 'solo@'
    assert_success
    assert_output ''
    run bu_location_resolve solo@nope
    assert_failure
    assert_output --partial 'has no worktree[nope]'
}

function test_repo_worktree_family_complete_and_resolve { #@test
    local base=$BATS_TEST_TMPDIR/wtrepo
    git init -q "$base"
    git -C "$base" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
    git -C "$base" worktree add -q "$BATS_TEST_TMPDIR"/wtrepo-worktree-foo -b feat/x
    git -C "$base" worktree add -q "$BATS_TEST_TMPDIR"/plainwt -b feat/y
    local foo_phys plain_phys
    foo_phys=$(cd "$BATS_TEST_TMPDIR"/wtrepo-worktree-foo && pwd -P)
    plain_phys=$(cd "$BATS_TEST_TMPDIR"/plainwt && pwd -P)

    bu_repo_register wtrepo --path "$base" --alias wr
    assert_equal "${BU_LOCATION_PROPERTIES[wtrepo,param_complete]}" __bu_repo_worktree_complete
    assert_equal "${BU_LOCATION_PROPERTIES[wtrepo,param_resolve]}" __bu_repo_worktree_resolve
    assert_equal "${BU_LOCATION_PROPERTIES[wtrepo,param_hint]}" worktree

    # completer: short names, prefix '<primary>-worktree-' stripped, self omitted
    __bu_repo_worktree_complete wtrepo
    assert_equal "$(printf '%s\n' "${BU_RET[@]}" | sort | paste -sd' ')" "foo plainwt"

    # resolver: short name, basename, branch
    bu_location_resolve wtrepo@foo
    assert_equal "$(cd "${BU_RET[0]}" && pwd -P)" "$foo_phys"
    bu_location_resolve wr@wtrepo-worktree-foo
    assert_equal "$(cd "${BU_RET[0]}" && pwd -P)" "$foo_phys"
    bu_location_resolve wtrepo@feat/x
    assert_equal "$(cd "${BU_RET[0]}" && pwd -P)" "$foo_phys"
    bu_location_resolve wtrepo@plainwt
    assert_equal "$(cd "${BU_RET[0]}" && pwd -P)" "$plain_phys"

    # names feed through the alias head
    run bu_location_names --kind dir 'wr@'
    assert_line 'wr@foo'
    assert_line 'wr@plainwt'

    # bare listing carries the stub AND the bare repo name
    run bu_location_names --tag repo ''
    assert_line wtrepo
    assert_line 'wtrepo@'
}

function test_repo_worktree_family_from_secondary_checkout { #@test
    local base=$BATS_TEST_TMPDIR/secrepo
    git init -q "$base"
    git -C "$base" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
    git -C "$base" worktree add -q "$BATS_TEST_TMPDIR"/secrepo-worktree-foo -b feat/x
    git -C "$base" worktree add -q "$BATS_TEST_TMPDIR"/secrepo-worktree-bar -b feat/z

    # the registered dir IS a secondary worktree: self (foo) omitted, the
    # primary appears under its plain basename
    bu_repo_register secfoo --path "$BATS_TEST_TMPDIR"/secrepo-worktree-foo
    __bu_repo_worktree_complete secfoo
    assert_equal "$(printf '%s\n' "${BU_RET[@]}" | sort | paste -sd' ')" "bar secrepo"
    bu_location_resolve secfoo@secrepo
    assert_equal "$(cd "${BU_RET[0]}" && pwd -P)" "$(cd "$base" && pwd -P)"
}

function test_repo_worktree_family_non_git_and_override { #@test
    mkdir -p "$BATS_TEST_TMPDIR"/notgit
    bu_repo_register ngr --path "$BATS_TEST_TMPDIR"/notgit
    run bu_location_resolve ngr@x
    assert_failure
    assert_output --partial 'not a git repo'    # adapted to the existing message text
    run bu_location_names --kind dir 'ngr@'
    assert_success
    assert_output ''

    # a caller-supplied pair wins over the git default
    myc() { BU_RET=(custom); }
    myr() { BU_RET=(/tmp); }
    bu_repo_register ovr --path /tmp --param-complete myc --param-resolve myr --param-hint mine
    assert_equal "${BU_LOCATION_PROPERTIES[ovr,param_complete]}" myc
    assert_equal "${BU_LOCATION_PROPERTIES[ovr,param_hint]}" mine
    bu_location_resolve ovr@custom
    assert_equal "${BU_RET[0]}" /tmp
}

function test_get_location_registry_param_default_hint { #@test
    default_complete() { BU_RET=(a); }
    default_resolve() { BU_RET=(/tmp); }
    bu_location_register nohint --param-complete default_complete --param-resolve default_resolve
    bu_location_register plainhint --path /tmp --param-hint unused
    local out
    out=$(bu get-location-registry --format jsonl | jq -c 'select(.name == "nohint") | {resolved, param}')
    assert_equal "$out" '{"resolved":"-","param":"value"}'
    out=$(bu get-location-registry --format jsonl | jq -r 'select(.name == "plainhint") | .param')
    assert_equal "$out" ''
    run bu_location_resolve nohint
    assert_failure
    assert_output --partial 'nohint@<value>'
}
