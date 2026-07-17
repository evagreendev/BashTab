#!/usr/bin/env bash

source "$BU_NULL"

bu_pushd_current "$BASH_SOURCE"

BU_AUTOCOMPLETE_USE_TREE_SITTER=true
eval "$(starship init bash)"
source <(fzf --bash)
export EDITOR=vim


bu import-environment +i -c ./commands -ns prefix

bu_popd_silent

