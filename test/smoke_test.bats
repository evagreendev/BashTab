#!/usr/bin/env -S bats --jobs 16
#
# Smoke tests: invoke --help on every registered command to catch
# breakage like missing entrypoint sourcing, syntax errors, or path
# resolution bugs.
#
# Each command is run in a clean subshell via `bu <cmd> --help` to
# keep state (pushd/popd, env, etc.) from leaking between tests.

setup() {
    load "test_helper/bats-assert/load.bash"
    load "test_helper/bats-support/load.bash"

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    # shellcheck source=../bu_entrypoint.sh
    source "$DIR"/../bu_entrypoint.sh

    # shellcheck source=./test_helper/bu_bats_decl.sh
    source "$BU_NULL"
}

# ── Helpers ─────────────────────────────────────────────────────────────

# Determine the dispatch type for a command using the same logic as bu_impl.
__smoke_command_type() {
    local cmd=$1
    local path_or_fn=${BU_COMMANDS[$cmd]:-}
    if [[ -z "$path_or_fn" ]]; then
        BU_RET=no-default-found
        return
    fi
    local cached=${BU_COMMAND_PROPERTIES[$cmd,type]:-}
    if [[ -n "$cached" ]]; then
        BU_RET=$cached
        return
    fi
    if bu_symbol_is_function "$path_or_fn"; then
        BU_RET=function
    elif [[ -x "$path_or_fn" ]]; then
        BU_RET=execute
    elif [[ -f "$path_or_fn" ]]; then
        BU_RET=source
    else
        BU_RET=no-default-found
    fi
}

# ── Smoke: --help on every registered command ────────────────────────────

# We generate one test per command to get clean per-command pass/fail reporting.
# Bats does not support dynamic test generation, so we use a single test that
# loops, but with explicit assert per command for clear reporting.

function test_all_commands_help { #@test
    local failures=()
    local cmd path_or_fn

    for cmd in $(printf '%s\n' "${!BU_COMMANDS[@]}" | sort); do
        path_or_fn=${BU_COMMANDS[$cmd]}

        __smoke_command_type "$cmd"
        local type=$BU_RET

        local exit_code=0

        case "$type" in
        execute)
            # Executable scripts: run in a subshell via `bu` dispatch
            run bash -c "source '$DIR'/../bu_entrypoint.sh 2>/dev/null; bu '$cmd' --help"
            exit_code=$status
            ;;
        source)
            # Sourceable scripts: bu dispatch handles sourcing
            run bash -c "source '$DIR'/../bu_entrypoint.sh 2>/dev/null; bu '$cmd' --help"
            exit_code=$status
            ;;
        function)
            # Function commands: bu dispatch calls the function
            run bash -c "source '$DIR'/../bu_entrypoint.sh 2>/dev/null; bu '$cmd' --help"
            exit_code=$status
            ;;
        alias)
            # Alias commands: bu resolves and dispatches
            run bash -c "source '$DIR'/../bu_entrypoint.sh 2>/dev/null; bu '$cmd' --help"
            exit_code=$status
            ;;
        *)
            # Skip unknown types
            continue
            ;;
        esac

        if [[ $exit_code -ne 0 ]]; then
            failures+=("$cmd (type=$type, exit=$exit_code)")
            printf 'FAIL: %-35s type=%-10s exit=%-3d\n' "$cmd" "$type" "$exit_code" >&2
            printf '  %s\n' "${output//$'\n'/$'\n'  }" >&2
        fi
    done

    if ((${#failures[@]} > 0)); then
        printf '\n%d command(s) failed --help:\n' "${#failures[@]}" >&2
        local f
        for f in "${failures[@]}"; do
            printf '  - %s\n' "$f" >&2
        done
        false  # trigger bats assertion failure
    fi
}
