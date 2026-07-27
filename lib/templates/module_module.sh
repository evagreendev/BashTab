#!/usr/bin/env bash
# ── Library registration ──────────────────────────────────────────
# This script is sourced via BU_MODULE_PATH BEFORE bu_entrypoint.sh
# finishes.  bu is NOT available here — only bu_register_module
# (which is defined before modules are sourced).
#
# Register the module name, version, and pre-init callback.
# The preinit runs later, during initialization, when bu IS available.

@MODULE_NAME@_DIR=$(realpath -- "$(dirname -- "${BASH_SOURCE}")")

bu_register_module "@MODULE_NAME@" "0.1.0" "$@MODULE_NAME@_DIR/@MODULE_NAME@_bu_preinit.sh"
