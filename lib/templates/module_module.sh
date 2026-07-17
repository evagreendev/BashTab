#!/usr/bin/env bash

@MODULE_NAME@_DIR=$(realpath -- "$(dirname -- "${BASH_SOURCE}")")

BU_USER_DEFINED_STATIC_PRE_INIT_ENTRYPOINT_CALLBACKS+=(
    "$@MODULE_NAME@_DIR"/@MODULE_NAME@_bu_preinit.sh
)
