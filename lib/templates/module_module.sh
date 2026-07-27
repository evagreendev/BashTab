#!/usr/bin/env bash
# ── Library registration ──────────────────────────────────────────
# This script is sourced via BU_MODULE_PATH BEFORE bu_entrypoint.sh
# finishes.  Append to BU_MODULE_LIST to register the module name,
# version, and preinit callback.  bu_entrypoint.sh parses this later
# and sources the preinit when bu IS available.

@MODULE_NAME@_DIR=$(realpath -- "$(dirname -- "${BASH_SOURCE}")")

BU_MODULE_LIST+="@MODULE_NAME@:0.1.0:$@MODULE_NAME@_DIR/@MODULE_NAME@_bu_preinit.sh;"
