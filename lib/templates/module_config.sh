#!/usr/bin/env bash
# ── Config registrations ──────────────────────────────────────────
# Sourced by bu_entrypoint.sh while BashTab's "main" config phase is open
# (found next to @MODULE_NAME@_bu_preinit.sh via BU_MODULE_LIST). Register
# every setting of this module here, so the environment, the settings files
# and these defaults are resolved together with BashTab's own settings.
# Settings final for the life of the shell go in
# @MODULE_NAME@_bu_config.static.sh instead (same form, static phase).
# $BU_CURRENT_MODULE_DIR is this module's directory.
#
# Example (allow your prefix once, then register):
#   if [[ " ${BU_CONFIG_NAME_PREFIXES[*]} " != *" MYMODULE_ "* ]]
#   then
#       BU_CONFIG_NAME_PREFIXES+=("MYMODULE_")
#   fi
#   bu_config_register MYMODULE_DATA_DIR --default "$BU_CURRENT_MODULE_DIR/data" \
#       --hint "Where @MODULE_NAME@ keeps its data"
