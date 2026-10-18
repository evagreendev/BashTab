#!/usr/bin/env bash
# devbox settings, registered while BashTab's "main" config phase is open.
# bu_entrypoint.sh finds this file next to devbox_bu_preinit.sh (from
# BU_MODULE_LIST) and resolves these settings with BashTab's own.

if [[ " ${BU_CONFIG_NAME_PREFIXES[*]} " != *" DEVBOX_ "* ]]
then
    BU_CONFIG_NAME_PREFIXES+=("DEVBOX_")
fi

bu_config_register DEVBOX_ENV_FILE \
    --default "$BU_CURRENT_MODULE_DIR/.bu/env.json" \
    --hint "Where devbox writes its last get-env snapshot"
