# shellcheck source=./bu_config_static.sh
source "$BU_NULL"

# Each setting is first declared with `bu_config_register` (metadata driving
# `bu set-config` validation/completion/listing), then assigned with
# ${VAR:-registered-default}: values set earlier (environment, or the
# machine-local config/bu_config_local.sh via `bu set-config`) take precedence.

# ```
# Whether to ignore cache when running bu_cached_execute
# ```
bu_config_register BU_INVALIDATE_CACHE --bool --default false \
    --hint "Ignore cache when running bu_cached_execute"
BU_INVALIDATE_CACHE=${BU_INVALIDATE_CACHE:-${BU_CONFIG_PROPERTIES[BU_INVALIDATE_CACHE,default]}}

# ```
# The log-level when running commands
# ```
bu_config_register BU_LOG_LVL --default "$BU_LOG_LVL_WARN" \
    --enum debug:"$BU_LOG_LVL_DEBUG" info:"$BU_LOG_LVL_INFO" warn:"$BU_LOG_LVL_WARN" err:"$BU_LOG_LVL_ERR" silence:"$BU_LOG_LVL_SILENCE" enum-- \
    --hint "Log level when running commands"
BU_LOG_LVL=${BU_LOG_LVL:-${BU_CONFIG_PROPERTIES[BU_LOG_LVL,default]}}

# ```
# The log-level when hitting TAB.
# In general, this should only log errors to avoid cluttering the
# autocomplete suggestions.
# ```
bu_config_register BU_AUTOCOMPLETE_LOG_LVL --default "$BU_LOG_LVL_ERR" \
    --enum debug:"$BU_LOG_LVL_DEBUG" info:"$BU_LOG_LVL_INFO" warn:"$BU_LOG_LVL_WARN" err:"$BU_LOG_LVL_ERR" silence:"$BU_LOG_LVL_SILENCE" enum-- \
    --hint "Log level during autocomplete (keep at err to avoid cluttering suggestions)"
BU_AUTOCOMPLETE_LOG_LVL=${BU_AUTOCOMPLETE_LOG_LVL:-${BU_CONFIG_PROPERTIES[BU_AUTOCOMPLETE_LOG_LVL,default]}}

bu_config_register BU_AUTOCOMPLETE_BIND_FZF_DISPLAY_METADATA --bool --default true \
    --hint "Show color-coded metadata (type tags, sizes) in fzf completion"
BU_AUTOCOMPLETE_BIND_FZF_DISPLAY_METADATA=${BU_AUTOCOMPLETE_BIND_FZF_DISPLAY_METADATA:-${BU_CONFIG_PROPERTIES[BU_AUTOCOMPLETE_BIND_FZF_DISPLAY_METADATA,default]}}

bu_config_register BU_AUTOCOMPLETE_BIND_TAB_TO_FZF --bool --default true \
    --hint "Bind Tab to fzf completion (Alt-Z toggles per session)"
BU_AUTOCOMPLETE_BIND_TAB_TO_FZF=${BU_AUTOCOMPLETE_BIND_TAB_TO_FZF:-${BU_CONFIG_PROPERTIES[BU_AUTOCOMPLETE_BIND_TAB_TO_FZF,default]}}

# ```
# Verbose bootstrap logging ("sourcing ..." lines during activation).
# Read before this file is loaded, so it only takes effect from the
# environment or config/bu_config_local.sh, not from editing this file.
# ```
bu_config_register BU_BOOTSTRAP_VERBOSE --bool --default false \
    --hint "Verbose logging during activation bootstrap (set via bu set-config)"
BU_BOOTSTRAP_VERBOSE=${BU_BOOTSTRAP_VERBOSE:-${BU_CONFIG_PROPERTIES[BU_BOOTSTRAP_VERBOSE,default]}}

# ```
# Use tree-sitter-bash (via node daemon) for command-line parsing
# in fzf autocomplete instead of the built-in bash parser.
# Provides more accurate cursor-position tracking and syntax awareness.
# ```
bu_config_register BU_AUTOCOMPLETE_USE_TREE_SITTER --bool --default false \
    --hint "Use tree-sitter-bash (node daemon) for command-line parsing in fzf autocomplete"
BU_AUTOCOMPLETE_USE_TREE_SITTER=${BU_AUTOCOMPLETE_USE_TREE_SITTER:-${BU_CONFIG_PROPERTIES[BU_AUTOCOMPLETE_USE_TREE_SITTER,default]}}

# Default output format for `bu out` / `bu * --format auto` when stdout is
# not a terminal can be overridden here. One of: table, list, json, jsonl, tsv
# Empty means: table on a terminal, jsonl otherwise.
bu_config_register BU_OUTPUT_FORMAT \
    --enum auto table list json jsonl tsv enum-- \
    --hint "Default output format when stdout is not a terminal (empty: table on tty, jsonl when piped)"
BU_OUTPUT_FORMAT=${BU_OUTPUT_FORMAT:-}

# Allow pipeline field completion to execute the pipeline prefix being typed
# ("probing") to discover record fields from live output. Off by default:
# only producers in BU_OUT_PROBE_COMMANDS are ever executed.
bu_config_register BU_OUT_PROBE_PIPELINE --bool --default false \
    --hint "Allow pipeline field completion to execute the pipeline prefix (probing)"
BU_OUT_PROBE_PIPELINE=${BU_OUT_PROBE_PIPELINE:-${BU_CONFIG_PROPERTIES[BU_OUT_PROBE_PIPELINE,default]}}
