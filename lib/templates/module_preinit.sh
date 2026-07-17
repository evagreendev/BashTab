#!/usr/bin/env bash

source "$BU_NULL"

bu_pushd_current "$BASH_SOURCE"

bu import-environment +i -c ./commands -ns prefix

bu_popd_silent

