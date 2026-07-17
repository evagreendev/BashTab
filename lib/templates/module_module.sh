#!/usr/bin/env bash

@MODULE_NAME@_DIR=$(realpath -- "$(dirname -- "${BASH_SOURCE}")")

__bu_module_register "@MODULE_NAME@" "0.1.0" "$@MODULE_NAME@_DIR/@MODULE_NAME@_bu_preinit.sh"
