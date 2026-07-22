case "${BASH_SOURCE}" in
*/*) pushd "${BASH_SOURCE%/*}" &>/dev/null ;; # Enter the current directory
*) pushd . &>/dev/null ;; # This seems like duplicate work but we need to match the popd later
esac

declare -a -g BU_RET=()
declare -A -g BU_RET_MAP=()
# `declare -p` check instead of "${#BU_MODULE_REGISTRY[@]}", which errors
# under `set -u` when the array has never been declared.
if ! declare -p BU_MODULE_REGISTRY &>/dev/null
then
    declare -A -g BU_MODULE_REGISTRY=()
fi

# ${VAR:-} guards: this file may be sourced from shells running `set -u`.
BU_REPO_DIR_PREV=${BU_REPO_DIR:-}
BU_REPO_SHA1_PREV=${BU_REPO_SHA1:-}
BU_REPO_DIR=$PWD
# Suppressed: users who downloaded a ZIP/tarball have no .git directory.
BU_REPO_SHA1=$(git rev-parse @ 2>/dev/null) || BU_REPO_SHA1=unknown
if [[ -n "$BU_REPO_SHA1_PREV" && "$BU_REPO_SHA1" != "$BU_REPO_SHA1_PREV" ]]
then
    echo "WARN    A different BashTab version is being activated: Prev[$BU_REPO_SHA1_PREV@$BU_REPO_DIR_PREV] Cur[$BU_REPO_SHA1@$BU_REPO_DIR]" >&2
fi

source ./bu_custom_source.sh --__bu-once

# Machine-local settings (uncommitted, managed by `bu set-config`). Sourced
# early so BU_BOOTSTRAP_VERBOSE applies to the sourcing logs below, and before
# bu_config_dynamic.sh, whose ${VAR:-default} assignments yield to these.
# Intentionally NOT --__bu-once: re-activation should re-read edited settings.
if [[ -f ./config/bu_config_local.sh ]]; then
    source ./config/bu_config_local.sh
fi

source ./lib/core/bu_core_user_defined.sh --__bu-once

# The BU_MODULE_PATH is the only variable that should be needed to get all external "libraries"
# i.e. BashTab related libraries setup.
# In particular, all the callbacks can be setup in these scripts
# To make it export-friendly, we will use a colon-separated string rather than an array.
if [[ -z "${BU_MODULE_PATH:-}" ]]
then
    declare -g BU_MODULE_PATH=
fi
export BU_MODULE_PATH

function __bu_source_modules()
{
    local paths=()
    local path
    bu_str_split : "$BU_MODULE_PATH" paths
    for path in "${paths[@]}"
    do
        # We allow empty paths, in which case we simply ignore them
        # This means BU_MODULE_PATH is quite freeform
        # The following are effectively equivalent
        # - a:b:c which is quite like a normal PATH-like variable
        # - a:b:c:
        # - a:::::b:c
        # - :a:b:c:
        if [[ -z "$path" ]]
        then
            continue
        fi

        if [[ ! -e "$path" ]]
        then
            bu_basic_log_err "bu module[$path] does not exist"
            continue
        fi

        if [[ -d "$path" ]]
        then
            bu_basic_log_err "bu module directory[$path] is not supported. Files only please."
            continue
        fi

        if [[ ! -f "$path" ]]
        then
            bu_basic_log_err "bu module[$path] is not a file??"
            continue
        fi

        source "$path" --__bu-once
    done
}
__bu_source_modules


source ./config/bu_config_static.sh --__bu-once
source ./config/bu_config_dynamic.sh

bu_source_user_defined_configs

source ./lib/core/bu_core_var.sh --__bu-once
source ./lib/core/bu_core_base.sh --__bu-once
source ./lib/core/bu_core_out.sh --__bu-once
source ./lib/core/bu_core_compat.sh --__bu-once
source ./lib/core/bu_core_cap.sh --__bu-once
bu_cap_init
source ./lib/core/bu_core_autocomplete.sh --__bu-once
source ./lib/core/bu_core_tmux.sh --__bu-once
source ./lib/core/bu_core_cli.sh --__bu-once
source ./lib/core/bu_core_preinit.sh --__bu-once

source ./lib/core/bu_core_early_init.sh

bu_source_user_defined_pre_init_callbacks

source ./lib/core/bu_core_init.sh

source ./lib/core/bu_core_ts.sh --__bu-once

# Warm-start the tree-sitter daemon at shell init so first Tab is instant.
# (~200ms one-time cost absorbed into shell startup)
if "$BU_AUTOCOMPLETE_USE_TREE_SITTER" && [[ -n "${BU_CAP[node]:-}" ]] && [[ $- == *i* ]]; then
    __bu_ts_daemon_start &>/dev/null
fi

popd &>/dev/null

bu_source_user_defined_post_entrypoint_callbacks

bu_log_info "Bash utils: fully set up"

# Sourcing may happen under `set -e`: never leak a non-zero status to the user's shell.
return 0
