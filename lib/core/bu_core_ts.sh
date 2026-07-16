#!/usr/bin/env bash

# Bash wrapper for the tree-sitter daemon.
#
# Uses bash coproc for bidirectional communication with the node daemon.
#
# Usage: source this file, then call bu_ts_parse CURSOR_OFFSET "COMMAND_LINE"
# Result stored in BU_TS_RESULT associative array.

if false; then
    source ../../../bu_custom_source.sh
fi

BU_TS_DAEMON=$BU_LIB_BIN_DIR/bu_ts_daemon.js
BU_TS_COPROC_PID=
BU_TS_TRAP_SET=

# Start the daemon via coproc if not running
__bu_ts_daemon_start()
{
    # Check if daemon is still alive
    if [[ -n "$BU_TS_COPROC_PID" ]] && kill -0 "$BU_TS_COPROC_PID" 2>/dev/null; then
        return 0
    fi

    # Clean up any stale coproc state from previous sourcing.
    # Closing the fds will cause the old node daemon to exit on EOF.
    if [[ -v BU_TS_COPROC ]]; then
        exec {BU_TS_COPROC[0]}>&- 2>/dev/null || true
        exec {BU_TS_COPROC[1]}>&- 2>/dev/null || true
        unset -v BU_TS_COPROC
    fi

    coproc BU_TS_COPROC { trap '' INT; node "$BU_TS_DAEMON"; }
    BU_TS_COPROC_PID=$!

    # Set exit trap once to clean up daemon on shell exit
    if [[ -z "$BU_TS_TRAP_SET" ]]; then
        trap 'bu_ts_daemon_stop' EXIT
        BU_TS_TRAP_SET=1
    fi

    # Read the ready signal
    local ready
    IFS= read -r -t 3 -u "${BU_TS_COPROC[0]}" ready
    if [[ "$ready" != '{"ready":true}' ]]; then
        bu_log_err "tree-sitter daemon did not send ready signal: $ready"
        return 1
    fi
    bu_log_info "tree-sitter daemon started (pid=$BU_TS_COPROC_PID)"
    return 0
}

# Parse a command line with tree-sitter.
# $1: cursor offset (byte position)
# $2: command line string
bu_ts_parse()
{
    local -r cursor_offset=$1
    local -r command_line=$2

    __bu_ts_daemon_start || return 1

    printf '%s:%s\n' "$cursor_offset" "$command_line" >&"${BU_TS_COPROC[1]}"

    local response
    IFS= read -r -t 3 -u "${BU_TS_COPROC[0]}" response || {
        bu_log_err "tree-sitter daemon timeout"
        return 1
    }

    # Parse JSON response into key=value pairs using a single node invocation
    local parsed
    parsed=$(node -e '
        const r = JSON.parse(require("fs").readFileSync("/dev/stdin","utf8").trim());
        const out = [];
        for (const [k, v] of Object.entries(r)) {
            if (typeof v === "string" || typeof v === "boolean" || typeof v === "number")
                out.push(k + "=" + String(v));
        }
        if (r.cursor) {
            for (const [k, v] of Object.entries(r.cursor)) {
                out.push("cursor," + k + "=" + String(v));
            }
        }
        out.push("cmdWords=" + (r.cmdWords || []).join("\x1f"));
        console.log(out.join("\n"));
    ' <<<"$response" 2>/dev/null) || {
        bu_log_err "Failed to parse tree-sitter response"
        return 1
    }

    declare -g -A BU_TS_RESULT=()
    local line key value
    while IFS='=' read -r key value; do
        BU_TS_RESULT[$key]=$value
    done <<<"$parsed"

    return 0
}

# Stop the daemon
bu_ts_daemon_stop()
{
    if [[ -n "$BU_TS_COPROC_PID" ]]; then
        kill "$BU_TS_COPROC_PID" 2>/dev/null || true
        wait "$BU_TS_COPROC_PID" 2>/dev/null || true
        { exec {BU_TS_COPROC[0]}>&-; } 2>/dev/null || true
        { exec {BU_TS_COPROC[1]}>&-; } 2>/dev/null || true
        BU_TS_COPROC_PID=
        BU_TS_TRAP_SET=
        bu_log_info "tree-sitter daemon stopped"
    fi
}
