BU_LOG_LVL_TRACE=0
BU_LOG_LVL_DEBUG=1
BU_LOG_LVL_INFO=2
BU_LOG_LVL_WARN=3
BU_LOG_LVL_ERR=4
BU_LOG_LVL_SILENCE=99

# Root output directory. BU_CACHE_DIR, BU_LOG_DIR, BU_TMP_DIR, and
# BU_HISTORY all derive from this (see bu_core_base.sh).
# Embedders can pre-set it before sourcing to relocate the entire tree.
export BU_OUT_DIR=${BU_OUT_DIR:-/tmp/bu/$USER}

BU_EXIT_HANDLER_VSCODE_POPUP=false

BU_TERMINAL_EDITOR_PREFERENCE=(vi nano vim emacs)
BU_VISUAL_EDITOR_PREFERENCE=(code codium)