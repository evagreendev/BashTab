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
# Human-readable release identity, derived from the datetime (CalVer) tags cut
# by release.sh.  `git describe --tags --always --dirty` yields e.g.
# "v2026.08.15-3-g1f4ae9c" (or "...-dirty" with uncommitted changes) and is
# stable/meaningless-free — no manual version bump to forget.
BU_VERSION=$(git describe --tags --always --dirty 2>/dev/null) || BU_VERSION=unknown
# Nearest release tag (empty → "unknown") for the `bu get-version` catalog.
BU_VERSION_TAG=$(git describe --tags --abbrev=0 2>/dev/null) || BU_VERSION_TAG=unknown
if [[ -n "$BU_REPO_SHA1_PREV" && "$BU_REPO_SHA1" != "$BU_REPO_SHA1_PREV" ]]
then
    echo "WARN    A different BashTab version is being activated: Prev[$BU_REPO_SHA1_PREV@$BU_REPO_DIR_PREV] Cur[$BU_REPO_SHA1@$BU_REPO_DIR] Cur-version[$BU_VERSION]" >&2
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

# BU_MODULE_LIST is the sole module registry — an exported scalar of the form
# "name:version:preinit_path;...".  Top-level projects set it in their activate
# script.  Library dependencies append to it in their module scripts.
# __bu_parse_module_list dedupes, populates BU_MODULE_REGISTRY, and registers
# preinit callbacks.  Runs after bu_core_var.sh so the registry arrays exist.
if [[ -z "${BU_MODULE_LIST:-}" ]]
then
    export BU_MODULE_LIST=
fi


source ./config/bu_config_static.sh --__bu-once
source ./config/bu_config_dynamic.sh

bu_source_user_defined_configs

source ./lib/core/bu_core_var.sh --__bu-once
source ./lib/core/bu_core_base.sh --__bu-once
# Location/repo/help-topic registries are re-sourced every activation (no
# --__bu-once) so their arrays reset before preinits and the local file
# re-register entries.
source ./lib/core/bu_core_location.sh
source ./lib/core/bu_core_repo.sh
source ./lib/core/bu_core_help_topic.sh
# BashTab's own subsystem topics live in <repo>/help and are registered from
# core (not a module preinit) so the builtin CLI always ships them. They
# re-register on every activation because bu_core_help_topic.sh resets the
# registry above, before module preinits add theirs. Core topics are stamped
# as module "bu" (the framework itself).
_bu_cur_module_prev=${BU_CURRENT_MODULE:-}
BU_CURRENT_MODULE=bu
bu_help_topic_register_dir "$BU_DIR/help"
BU_CURRENT_MODULE=$_bu_cur_module_prev
source ./lib/core/bu_core_out.sh --__bu-once
source ./lib/core/bu_core_compat.sh --__bu-once
source ./lib/core/bu_core_cap.sh --__bu-once
bu_cap_init
source ./lib/core/bu_core_autocomplete.sh --__bu-once
source ./lib/core/bu_core_help_parse.sh --__bu-once
source ./lib/core/bu_core_tmux.sh --__bu-once
source ./lib/core/bu_core_cli.sh --__bu-once
source ./lib/core/bu_core_expose.sh --__bu-once
source ./lib/core/bu_core_preinit.sh --__bu-once

# Now that all registry arrays are declared, parse BU_MODULE_LIST.
__bu_parse_module_list

source ./lib/core/bu_core_cache.sh --__bu-once
__bu_try_load_command_cache || true

source ./lib/core/bu_core_early_init.sh

bu_source_user_defined_pre_init_callbacks

# User-local named locations (after preinits so user registrations win).
bu_location_source_local_file

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
