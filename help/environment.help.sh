# Synopsis: BashTab's session environment and activation lifecycle

# Live checks. This file is sourced in a subshell by `bu get-help`, so plain
# assignments here cannot leak into the invoking shell.

_out_dir=${BU_OUT_DIR:-<unset>}
_cache_dir=${BU_CACHE_DIR:-<unset>}
_log_dir=${BU_LOG_DIR:-<unset>}
_tmp_dir=${BU_TMP_DIR:-<unset>}
_history=${BU_HISTORY:-<unset>}
_top_module=${BU_TOP_LEVEL_MODULE:-<none>}
_cli=${BU_CLI_COMMAND_NAME:-bu}

_cmd_table=$(bu_help_topic_commands_tagged environment "$BU_BUILTIN_COMMANDS_DIR/core")

cat <<EOF
${BU_TPUT_BOLD}NAME${BU_TPUT_RESET}
    environment — BashTab's session environment and activation lifecycle

${BU_TPUT_BOLD}SYNOPSIS${BU_TPUT_RESET}
    source ./activate
    bu import-environment -c ./commands -ns prefix
    bu import-environment --reset-leaky

${BU_TPUT_BOLD}DESCRIPTION${BU_TPUT_RESET}
    "The environment" is the loaded shell state: the command registry, the
    module list, the source-once cache, and the machine-local output tree.
    Activation walks a fixed lifecycle:

        activate → bu_entrypoint.sh → module preinits → user-local files → init

    bu import-environment is the re-entry point for that lifecycle. A module's
    activate script calls it to register command dirs and reinitialize; a
    preinit callback uses it to register its commands with a namespace style.

${BU_TPUT_BOLD}import-environment OPTIONS${BU_TPUT_RESET}
    -c, --command-dir DIR   register a command-search directory (repeatable)
    -ns, --namespace-style  none | prefix | powershell | prefix-keep | powershell-keep
    -nr, --non-recursive    scan only the top level (subdirs become libraries)
    -p, --pull              git pull the BashTab repo (or submodule)
    +i, --no-init           skip the entrypoint re-source (successive calls)
    -f, --force             re-source even already-sourced files

${BU_TPUT_BOLD}RESET SEMANTICS${BU_TPUT_RESET}
    --reset-source        clear the source-once cache (force full re-source)
    --reset-vars          re-run bu_core_var.sh (reinitialize globals)
    --reset-module-path   clear BU_MODULE_LIST (deregister other modules)
    --reset-leaky         reset source+vars but let BU_MODULE_LIST leak through
    --reset-all           reset source+vars+module-path (near-clean slate)

${BU_TPUT_BOLD}OUTPUT TREE${BU_TPUT_RESET}
    One root directory relocates the whole tree. Set BU_OUT_DIR before
    sourcing to move cache, logs, temp files, and history together.

        BU_OUT_DIR=/somewhere/else source ./activate

${BU_TPUT_BOLD}THIS MACHINE${BU_TPUT_RESET}
    CLI:               $_cli
    top-level module:  $_top_module
    BU_OUT_DIR:        $_out_dir
    cache / log:       $_cache_dir
                      $_log_dir
    tmp:               $_tmp_dir
    history:           $_history

${BU_TPUT_BOLD}COMMANDS${BU_TPUT_RESET}
    Derived from commands/core/ — files tagged # Help-Topic: environment:

$_cmd_table

${BU_TPUT_BOLD}TYPICAL FLOWS${BU_TPUT_RESET}
    Re-register commands after editing a config file:
        bu import-environment --force

    Add a command directory with namespace stripping:
        bu import-environment -c ./commands -ns prefix

    Start over from a mostly-clean slate (keeping BU_MODULE_LIST):
        bu import-environment --reset-leaky

${BU_TPUT_BOLD}FAILURE SIGNATURES${BU_TPUT_RESET}
    "dir[...] does not exist" on -c/--command-dir
        The command directory path is wrong; the scan has nothing to search.

    Command list still stale after editing commands
        The command cache was loaded from a prior activation. Run
        bu clear-cache <module> and re-activate, or set
        BU_COMMAND_CACHE_ENABLED=false.

    "Could not expand location path expression" after changing \$VAR
        A lazy path referenced an unset variable at resolve time. Export the
        variable before using the location.

${BU_TPUT_BOLD}SEE ALSO${BU_TPUT_RESET}
    bu get-module           list loaded modules
    bu get-config           list configuration settings
    bu get-cache            list cached project registries
    docs/getting_started.md   activation quick start
EOF
