#!/usr/bin/env bash
# ── Binary entrypoint ──────────────────────────────────────────────
# Source this file to activate the @MODULE_NAME@ shell environment.
#
# Lifecycle:
#   1. BEFORE source bu_entrypoint.sh  → bu is NOT available yet
#   2. source bu_entrypoint.sh          → bu IS available (builtins + your commands)
#   3. bu_mark_load_complete            → cache the command registry
#   4. @MODULE_NAME@_init               → your custom init (bu is available here)
#
# Usage:
#   source ./activate                  # first time: full scan, saves cache
#   source ./activate                  # subsequent: loads cache, instant
#   bu clear-cache @MODULE_NAME@       # invalidate after adding commands
function @MODULE_NAME@_activate()
{
    local @MODULE_NAME@_invocation_dir=$PWD
    pushd "$(dirname -- "${BASH_SOURCE}")" &>/dev/null
    local @MODULE_NAME@_dir=$PWD

    eval "$(fzf --bash)"

    # ── BEFORE bu_entrypoint.sh: bu may or may not be available ──
    # If bu exists from a parent environment, reset leaky state first.
    if command -v bu &>/dev/null
    then
        bu import-environment --reset-leaky --no-init
    fi

    if [[ "$BU_MODULE_PATH" != *@MODULE_NAME@_bu_module.sh* ]]
    then
        BU_MODULE_PATH+=:$@MODULE_NAME@_dir/@MODULE_NAME@_bu_module.sh
    fi

    # Set the top-level module key so the command registry can be cached.
    # Must be set before sourcing bu_entrypoint.sh so the cache is checked.
    export BU_TOP_LEVEL_MODULE="${BU_TOP_LEVEL_MODULE:-@MODULE_NAME@}"

    # ── Main init: bu becomes available here ──────────────────────
    source "$BU_DIR"/bu_entrypoint.sh

    # Cache the command registry so subsequent activations skip the scan.
    # No-op if the cache was already loaded from disk.
    bu_mark_load_complete

    # ── AFTER init: bu is fully available ─────────────────────────
    # Use bu new-command, bu import-environment, etc. here or in _init.

    bu_scope_push_function
    bu_scope_add_cleanup bu_popd_silent

    @MODULE_NAME@_init

    bu_scope_pop_function
}


@MODULE_NAME@_activate "$@"
