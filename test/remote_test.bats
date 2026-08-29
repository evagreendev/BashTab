#!/usr/bin/env -S bats --jobs 16

# Tier-1 tests for lib/core/bu_core_remote.sh and the commands/remote/*
# commands.  No network, no sshd, no key trust: a PATH-stub ssh records argv
# and plays back canned responses, and the local short-circuit exercises the
# full marshal->run->tag->rc path with zero network.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # shellcheck source=../bu_entrypoint.sh
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"

    # Isolated, short socket directory (sun_path is ~100 bytes).
    export BU_REMOTE_SSH_DIR="$BATS_TEST_TMPDIR/sshdir"

    # Stub ssh on PATH: records argv, plays back canned behavior.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
# Stub ssh: record argv to a log, then play back behavior chosen by the
# BU_TEST_SSH_* environment variables.
printf '%s\n' "$*" >> "${BU_TEST_SSH_ARGV_LOG:?}"

prev=
op=
for a in "$@"; do
    if [[ "$a" == "-fN" ]]; then
        exit "${BU_TEST_SSH_FN_RC:-0}"
    fi
    if [[ "$prev" == "-O" ]]; then
        op=$a
        break
    fi
    prev=$a
done

case "$op" in
check)
    if [[ "${BU_TEST_SSH_CHECK_RC:-0}" != 0 ]]; then
        echo "Control socket connect: No such file or directory" >&2
        exit "${BU_TEST_SSH_CHECK_RC}"
    fi
    echo "Master running (pid=${BU_TEST_SSH_PID:-1234})" >&2
    exit 0
    ;;
exit)
    if [[ "${BU_TEST_SSH_EXIT_RC:-0}" != 0 ]]; then
        echo "Control socket connect: No such file or directory" >&2
        exit "${BU_TEST_SSH_EXIT_RC}"
    fi
    exit 0
    ;;
*)
    echo "stub-connect-failed" >&2
    exit "${BU_TEST_SSH_DEFAULT_RC:-255}"
    ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export BU_TEST_SSH_ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
    export BU_TEST_SSH_FN_RC=0
    export BU_TEST_SSH_CHECK_RC=0
    export BU_TEST_SSH_EXIT_RC=0
    export BU_TEST_SSH_PID=1234
    export BU_TEST_SSH_DEFAULT_RC=255
}

# local username, mirroring __bu_remote_local_user's $USER fallback
local_user() {
    echo "${USER:-$(id -un 2>/dev/null)}"
}

# ===========================================================================
# Pure helpers: spec normalization
# ===========================================================================

function test_remote_spec_normalize_bare_host { #@test
    local rc=0
    bu_remote_spec_normalize web01 || rc=$?
    assert_equal "$rc" 0
    assert_equal "$BU_RET" "$(local_user)@web01"
    assert_equal "${BU_RET_MAP[user]}" "$(local_user)"
    assert_equal "${BU_RET_MAP[host]}" web01
}

function test_remote_spec_normalize_user_host { #@test
    local rc=0
    bu_remote_spec_normalize deploy@web01 || rc=$?
    assert_equal "$rc" 0
    assert_equal "$BU_RET" "deploy@web01"
    assert_equal "${BU_RET_MAP[user]}" deploy
    assert_equal "${BU_RET_MAP[host]}" web01
}

function test_remote_spec_normalize_rejections { #@test
    local bad
    for bad in 'has space' 'a/b' '' 'a@b@c' 'x@' '@y' 'semi;colon'
    do
        run bu_remote_spec_normalize "$bad"
        assert_failure
    done
}

# ===========================================================================
# Pure helpers: socket path
# ===========================================================================

function test_remote_socket_path_shape { #@test
    local rc=0
    bu_remote_socket web01 || rc=$?
    assert_equal "$rc" 0
    assert_equal "$BU_RET" "$BU_REMOTE_SSH_DIR/cm-$(local_user)@web01"
}

function test_remote_socket_sun_path_guard { #@test
    local long_dir
    long_dir="/$(printf 'x%.0s' {1..120})"
    BU_REMOTE_SSH_DIR="$long_dir"
    run bu_remote_socket web01
    assert_failure
}

# ===========================================================================
# Pure helpers: ssh opts (master gating)
# ===========================================================================

function test_remote_ssh_opts_without_master { #@test
    bu_remote_session_alive() { return 1; }
    local -a opts=()
    bu_remote_ssh_opts web01 opts
    assert_equal "${#opts[@]}" 2
    assert_equal "${opts[*]}" "-o BatchMode=yes"
}

function test_remote_ssh_opts_with_master { #@test
    bu_remote_session_alive() { return 0; }
    bu_remote_socket web01
    local sock=$BU_RET
    local -a opts=()
    bu_remote_ssh_opts web01 opts
    assert_equal "${opts[*]}" "-o BatchMode=yes -o ControlPath=$sock"
}

# ===========================================================================
# Host-injection jq constant
# ===========================================================================

function test_remote_jq_host_filter_tags_json { #@test
    local out
    out=$(printf '%s\n' '{"a":1}' | jq -Rr --arg host h "$BU_REMOTE_JQ_HOST_FILTER")
    assert_equal "$out" '{"a":1,"host":"h"}'
}

function test_remote_jq_host_filter_overwrites_host { #@test
    local out
    out=$(printf '%s\n' '{"host":"old","a":1}' | jq -Rr --arg host h "$BU_REMOTE_JQ_HOST_FILTER")
    assert_equal "$out" '{"host":"h","a":1}'
}

function test_remote_jq_host_filter_passes_raw { #@test
    local out
    out=$(printf '%s\n' 'not json' | jq -Rr --arg host h "$BU_REMOTE_JQ_HOST_FILTER")
    assert_equal "$out" 'not json'
}

# ===========================================================================
# Script assembly
# ===========================================================================

function test_remote_build_script_preamble_order { #@test
    local out
    out=$(bu_remote_build_script "" command get-module)
    assert_equal "$(sed -n '1p' <<<"$out")" "set -e"
    assert_equal "$(sed -n '2p' <<<"$out")" ". /etc/profile >/dev/null 2>&1 || true"
    assert_equal "$(sed -n '3p' <<<"$out")" ". ~/.bashrc >/dev/null 2>&1 || true"
}

function test_remote_build_script_callback_embedding { #@test
    __test_remote_cb() { echo "MARKER_REMOTE_DIR=$1"; echo "__bu_remote_dispatch() { :; }"; }
    BU_REMOTE_BOOTSTRAP_CALLBACK=__test_remote_cb
    run bu_remote_build_script /opt/app command get-module
    assert_success
    assert_output --partial 'MARKER_REMOTE_DIR=/opt/app'
    assert_output --partial '__bu_remote_dispatch() { :; }'
}

function test_remote_build_script_percent_q_quoting { #@test
    local out
    out=$(bu_remote_build_script "" command 'a b' '$HOME')
    assert_equal "$(tail -n1 <<<"$out")" '__bu_remote_dispatch a\ b \$HOME'
}

function test_remote_build_script_script_mode_wrapper { #@test
    local out
    out=$(bu_remote_build_script "" script $'echo hi\nget-module')
    assert_equal "$(grep -c '^set +e$' <<<"$out")" 1
    assert_equal "$(grep -c '^fn() { set -e$' <<<"$out")" 1
    assert_equal "$(grep -c '^echo hi$' <<<"$out")" 1
    assert_equal "$(grep -c '^get-module$' <<<"$out")" 1
    assert_equal "$(grep -c '^}$' <<<"$out")" 1
    assert_equal "$(grep -c '^fn$' <<<"$out")" 1
    assert_equal "$(grep -c '^exit \$?$' <<<"$out")" 1
}

function test_remote_build_script_default_stanza_only_when_unset { #@test
    unset BU_REMOTE_BOOTSTRAP_CALLBACK
    local out
    out=$(bu_remote_build_script "" command get-module)
    assert_equal "$(grep -Fc '__bu_remote_dispatch() { bu "$@"; }' <<<"$out")" 1
    assert_equal "$(grep -c 'register BU_REMOTE_BOOTSTRAP_CALLBACK' <<<"$out")" 1

    __test_remote_cb2() { echo "CUSTOM_BOOTSTRAP"; }
    BU_REMOTE_BOOTSTRAP_CALLBACK=__test_remote_cb2
    out=$(bu_remote_build_script "" command get-module)
    assert_equal "$(grep -c 'CUSTOM_BOOTSTRAP' <<<"$out")" 1
    assert_equal "$(grep -Fc '__bu_remote_dispatch() { bu "$@"; }' <<<"$out")" 0
}

# ===========================================================================
# End-to-end WITHOUT network: local short-circuit
# ===========================================================================

__test_remote_bootstrap() {
    cat <<'EOF'
__bu_remote_dispatch() {
    if [[ "$1" == fail ]]; then
        echo "ERR: boom" >&2
        return 42
    fi
    printf '%s\n' '{"name":"test","value":1}'
}
EOF
}

function test_remote_invoke_local_short_circuit_inject { #@test
    BU_REMOTE_BOOTSTRAP_CALLBACK=__test_remote_bootstrap
    local script
    script=$(mktemp "$BATS_TEST_TMPDIR/script.XXXXXX")
    bu_remote_build_script "" command run > "$script"

    run bu_remote_invoke "$script" true localhost
    assert_success
    assert_output "{\"name\":\"test\",\"value\":1,\"host\":\"$(local_user)@localhost\"}"
}

function test_remote_invoke_local_no_host_field { #@test
    BU_REMOTE_BOOTSTRAP_CALLBACK=__test_remote_bootstrap
    local script
    script=$(mktemp "$BATS_TEST_TMPDIR/script.XXXXXX")
    bu_remote_build_script "" command run > "$script"

    run bu_remote_invoke "$script" false localhost
    assert_success
    assert_output '{"name":"test","value":1}'
}

function test_remote_invoke_local_rc_propagation { #@test
    BU_REMOTE_BOOTSTRAP_CALLBACK=__test_remote_bootstrap
    local script
    script=$(mktemp "$BATS_TEST_TMPDIR/script.XXXXXX")
    bu_remote_build_script "" command fail > "$script"

    run bu_remote_invoke "$script" true localhost
    assert_failure 42
}

# ===========================================================================
# ssh-branch coverage WITHOUT network (PATH-stub ssh)
# ===========================================================================

function test_remote_invoke_ssh_argv { #@test
    local script
    script=$(mktemp "$BATS_TEST_TMPDIR/script.XXXXXX")
    printf 'echo ok\n' > "$script"

    run bu_remote_invoke "$script" false web01
    assert_failure
    assert_equal "$(cat "$BU_TEST_SSH_ARGV_LOG")" "-o BatchMode=yes $(local_user)@web01 bash -s"
}

function test_remote_invoke_ssh_argv_with_master { #@test
    bu_remote_session_alive() { return 0; }
    bu_remote_socket web01
    local sock=$BU_RET
    local script
    script=$(mktemp "$BATS_TEST_TMPDIR/script.XXXXXX")
    printf 'echo ok\n' > "$script"

    run bu_remote_invoke "$script" false web01
    assert_failure
    assert_equal "$(cat "$BU_TEST_SSH_ARGV_LOG")" "-o BatchMode=yes -o ControlPath=$sock $(local_user)@web01 bash -s"
}

function test_remote_invoke_ssh_stderr_prefix { #@test
    local script
    script=$(mktemp "$BATS_TEST_TMPDIR/script.XXXXXX")
    printf 'echo ok\n' > "$script"

    run bu_remote_invoke "$script" false web01
    assert_failure
    assert_output --partial "[$(local_user)@web01] stub-connect-failed"
}

function test_new_remote_session_created { #@test
    run bu new-remote-session web01
    assert_success
    assert_equal "$(jq -r .host <<<"$output")" "$(local_user)@web01"
    assert_equal "$(jq -r .action <<<"$output")" created
    assert_equal "$(jq -r .master_pid <<<"$output")" 1234
}

function test_new_remote_session_reused { #@test
    bu_remote_session_alive() { return 0; }
    run bu new-remote-session web01
    assert_success
    assert_equal "$(jq -r .action <<<"$output")" reused
    assert_equal "$(jq -r .master_pid <<<"$output")" 1234
}

function test_new_remote_session_failed { #@test
    export BU_TEST_SSH_FN_RC=255
    export BU_TEST_SSH_CHECK_RC=255
    run bu new-remote-session web01
    assert_failure
    assert_output --partial '"action":"failed"'
}

function test_get_remote_session_recover_and_dead { #@test
    mkdir -p "$BU_REMOTE_SSH_DIR"
    touch "$BU_REMOTE_SSH_DIR/cm-$(local_user)@host1"
    export BU_TEST_SSH_CHECK_RC=255
    run bu get-remote-session
    assert_success
    assert_equal "$(jq -r .host <<<"$output")" "$(local_user)@host1"
    assert_equal "$(jq -r .alive <<<"$output")" "false"
    assert_equal "$(jq -r .master_pid <<<"$output")" ""
}

function test_get_remote_session_alive { #@test
    mkdir -p "$BU_REMOTE_SSH_DIR"
    touch "$BU_REMOTE_SSH_DIR/cm-$(local_user)@host1"
    export BU_TEST_SSH_PID=4321
    run bu get-remote-session
    assert_success
    assert_equal "$(jq -r .host <<<"$output")" "$(local_user)@host1"
    assert_equal "$(jq -r .alive <<<"$output")" "true"
    assert_equal "$(jq -r .master_pid <<<"$output")" "4321"
}

function test_remove_remote_session_closed { #@test
    mkdir -p "$BU_REMOTE_SSH_DIR"
    touch "$BU_REMOTE_SSH_DIR/cm-$(local_user)@host1"
    run bu remove-remote-session host1
    assert_success
    assert_equal "$(jq -r .action <<<"$output")" closed
    assert [ ! -e "$BU_REMOTE_SSH_DIR/cm-$(local_user)@host1" ]
}

function test_remove_remote_session_removed_stale { #@test
    mkdir -p "$BU_REMOTE_SSH_DIR"
    touch "$BU_REMOTE_SSH_DIR/cm-$(local_user)@host1"
    export BU_TEST_SSH_EXIT_RC=255
    run bu remove-remote-session host1
    assert_success
    assert_equal "$(jq -r .action <<<"$output")" removed-stale
    assert [ ! -e "$BU_REMOTE_SSH_DIR/cm-$(local_user)@host1" ]
}

function test_remove_remote_session_absent { #@test
    run bu remove-remote-session host1
    assert_success
    assert_equal "$(jq -r .action <<<"$output")" absent
}

# ===========================================================================
# Alias binding
# ===========================================================================

function test_alias_bound_after_init { #@test
    assert_equal "${BU_COMMANDS[invoke-command]}" "invoke-remote-command {...}"
    assert_equal "${BU_COMMAND_PROPERTIES[invoke-command,type]}" alias
}

function test_alias_suppressed_when_preclaimed { #@test
    unset 'BU_COMMANDS[invoke-command]'
    BU_COMMANDS[invoke-command]="my-custom-invoke"
    BU_COMMAND_PROPERTIES[invoke-command,type]=function
    __bu_remote_register_alias
    assert_equal "${BU_COMMANDS[invoke-command]}" "my-custom-invoke"
    assert_equal "${BU_COMMAND_PROPERTIES[invoke-command,type]}" function
}
