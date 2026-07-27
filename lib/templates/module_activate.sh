#!/usr/bin/env bash
function @MODULE_NAME@_activate()
{
    local @MODULE_NAME@_invocation_dir=$PWD
    pushd "$(dirname -- "${BASH_SOURCE}")" &>/dev/null
    local @MODULE_NAME@_dir=$PWD

    eval "$(fzf --bash)"

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

    source "$BU_DIR"/bu_entrypoint.sh

    bu_mark_load_complete

    bu_scope_push_function
    bu_scope_add_cleanup bu_popd_silent

    @MODULE_NAME@_init

    bu_scope_pop_function
}


@MODULE_NAME@_activate "$@"
