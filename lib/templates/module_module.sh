#!/usr/bin/env bash
# ── Library registration ──────────────────────────────────────────
# This script appends to BU_MODULE_LIST to register the module name,
# version, and preinit callback.  bu_entrypoint.sh parses this later
# and sources the preinit when bu IS available.

@MODULE_NAME@_DIR=$(realpath -- "$(dirname -- "${BASH_SOURCE}")")

BU_MODULE_LIST+="@MODULE_NAME@:0.1.0:$@MODULE_NAME@_DIR/@MODULE_NAME@_bu_preinit.sh;"

# Optional: require your own library dependencies.  Diamond-safe — the host
# that sources this file must already have lib/bu_module_require.sh loaded
# (top-level activates do), and nested requires return 0 immediately when a
# dependency is already registered:
#   bu_module_require somedep --dir "$@MODULE_NAME@_DIR/../somedep"
