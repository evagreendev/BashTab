#!/usr/bin/env bash
# ── Library registration ──────────────────────────────────────────
# gitshelf_bu_module.sh is the LIBRARY entrypoint of the gitshelf module.
#
# WHEN THIS FILE IS SOURCED:
#   By a HOST project's activate script — BEFORE the host sources
#   bu_entrypoint.sh. See examples/devbox/activate. It is the counterpart to
#   gitshelf/activate (the BINARY entrypoint); a host must never source that
#   one, because it would fight the host for the top-level role.
#
# WHAT IT DOES:
#   Appends one `name:version:preinit_path;` entry to BU_MODULE_LIST, the
#   sole module registry. bu_entrypoint.sh parses that list later and sources
#   the preinit callback when bu IS available. Nothing else: no bu_* calls,
#   no bu_mark_load_complete — the host owns initialization and caching.
case "${BASH_SOURCE}" in
    */*) GITSHELF_MODULE_DIR=$(cd -- "${BASH_SOURCE%/*}" && pwd -P) ;;
    *)   GITSHELF_MODULE_DIR=$PWD ;;
esac
BU_MODULE_LIST+="gitshelf:0.1.0:${GITSHELF_MODULE_DIR}/gitshelf_bu_preinit.sh;"
unset GITSHELF_MODULE_DIR
