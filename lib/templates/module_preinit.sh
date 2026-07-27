#!/usr/bin/env bash
# ── Pre-init callback ─────────────────────────────────────────────
# This script runs DURING bu_entrypoint.sh initialization (registered
# by @MODULE_NAME@_bu_module.sh via bu_register_module).
#
# bu IS available here — the early init phase already registered the
# builtin commands.  Use +i (--no-init) to avoid re-sourcing
# bu_entrypoint.sh since we're already inside it.

source "$BU_NULL"

bu_pushd_current "$BASH_SOURCE"

# Register this module's commands directory.
# Add more registrations here (key bindings, completion funcs, aliases).
bu import-environment +i -c ./commands -ns prefix

bu_popd_silent

