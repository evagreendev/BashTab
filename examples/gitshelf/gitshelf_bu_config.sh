#!/usr/bin/env bash
# gitshelf settings, registered while BashTab's "main" config phase is open.
# bu_entrypoint.sh finds this file next to gitshelf_bu_preinit.sh (from
# BU_MODULE_LIST) and resolves these settings with BashTab's own: an exported
# value wins, then the settings files, then the defaults below.

# Allow GITSHELF_* settings in `bu set-config` / `bu get-config`. Guarded:
# this file runs on every activation of the same shell.
if [[ " ${BU_CONFIG_NAME_PREFIXES[*]} " != *" GITSHELF_ "* ]]
then
    BU_CONFIG_NAME_PREFIXES+=("GITSHELF_")
fi

bu_config_register GITSHELF_CONFIG_FILE \
    --default "$BU_CURRENT_MODULE_DIR/config/shelf.json" \
    --hint "Path to the gitshelf repo config (shelf.json)"
