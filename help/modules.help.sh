# Synopsis: BashTab's module system: BU_MODULE_LIST, binary vs library, caching

# Live checks. This file is sourced in a subshell by `bu get-help`, so plain
# assignments here cannot leak into the invoking shell.

_cache_dir=${BU_CACHE_DIR:-<unset>}
_top_module=${BU_TOP_LEVEL_MODULE:-<none>}

_modules_table=$(for _name in "${!BU_MODULE_REGISTRY[@]}"; do
    _entry=${BU_MODULE_REGISTRY[$_name]}
    _ver=${_entry%%:*}
    _path=${_entry#*:}
    printf '    %-16s %-12s %s\n' "$_name" "$_ver" "$_path"
done | sort)
[[ -n "$_modules_table" ]] || _modules_table="    (none loaded)"

_cmd_table=$(bu_help_topic_commands_tagged modules "$BU_BUILTIN_COMMANDS_DIR/core")

cat <<EOF
${BU_TPUT_BOLD}NAME${BU_TPUT_RESET}
    modules — BashTab's module system

${BU_TPUT_BOLD}SYNOPSIS${BU_TPUT_RESET}
    export BU_MODULE_LIST="myapp:0.1.0:/path/to/myapp_bu_preinit.sh;"
    source ./bu_entrypoint.sh
    bu get-module

${BU_TPUT_BOLD}DESCRIPTION${BU_TPUT_RESET}
    A module is how code (commands, aliases, keybindings, settings) packages
    itself for BashTab. BU_MODULE_LIST is the sole registry — an exported
    scalar of the form "name:version:preinit_path;...". The entrypoint parses
    it (deduping by name), sources each preinit callback, and populates
    BU_MODULE_REGISTRY for bu get-module. No hand-maintained lists anywhere.

    Modules follow Rust's library/binary model:

        Mode      Entrypoint              Sets BU_TOP_LEVEL_MODULE?   Caches?
        --------  ----------------------  --------------------------  -------
        Binary    activate                yes (before entrypoint)     yes (bu_mark_load_complete)
        Library   *_bu_module.sh (appends to BU_MODULE_LIST)  no (inherits host)   no (host caches)

    The same module can do both: activate is its "binary" entrypoint,
    *_bu_module.sh is its "library" entrypoint. Only the top-level binary calls
    bu_mark_load_complete.

${BU_TPUT_BOLD}PREREQUISITES${BU_TPUT_RESET}
    The preinit callback is sourced during init, AFTER the core registry arrays
    are reset and BEFORE user-local overrides. That is where a module registers
    its command directories, completion functions, keybindings, and aliases:

        bu_preinit_register_user_defined_subcommand_dir   \$DIR/commands ...
        bu_preinit_register_user_defined_completion_func  mycmd __my_completion
        bu_preinit_register_user_defined_key_binding      '\\em' my_edit
        bu_preinit_register_new_alias                     gc get-command ...

    Use bu new-module --name NAME to scaffold the standard layout, and
    bu new-command --dir commands --name CMD to add commands to it.

${BU_TPUT_BOLD}CACHE LIFECYCLE${BU_TPUT_RESET}
    First activation of a top-level module does a full command scan and saves a
    cache under its BU_TOP_LEVEL_MODULE key. Subsequent activations load the
    cache and skip the scan. After adding/removing commands:

        bu clear-cache <module>     # invalidate one project
        bu clear-cache --all        # invalidate everything

    Disable caching entirely with BU_COMMAND_CACHE_ENABLED=false (dynamic module
    systems), or relocate the whole output tree with BU_OUT_DIR.

${BU_TPUT_BOLD}THIS MACHINE${BU_TPUT_RESET}
    top-level module:  $_top_module
    cache directory:   $_cache_dir
    loaded modules:

$_modules_table

${BU_TPUT_BOLD}COMMANDS${BU_TPUT_RESET}
    Derived from commands/core/ — only files tagged # Help-Topic: modules:

$_cmd_table

${BU_TPUT_BOLD}TYPICAL FLOWS${BU_TPUT_RESET}
    Embed BashTab in a project:
        git submodule add <bash-tab-url> deps/bash-tab
        source deps/bash-tab/activate
        bu new-module --name myproject
        source ./myproject/activate
        bu new-command --dir commands --name deploy

    Use your module as a library dependency of another project:
        # in the host project's activate:
        BU_MODULE_LIST+="myproject:0.1.0:/path/to/myproject_bu_preinit.sh;"

${BU_TPUT_BOLD}FAILURE SIGNATURES${BU_TPUT_RESET}
    "dir[...] does not exist" during a preinit
        A bu_preinit_register_user_defined_subcommand_dir path is wrong — the
        preinit runs before its module's commands are available.

    Command appears once in bu get-command but twice in the dropdown
        A command directory was registered twice (e.g. both the module preinit
        and the host). Dedup the search dirs.

    Stale command list after adding a command
        The command cache was loaded from a previous activation. Run
        bu clear-cache <module> and re-activate.

    "bu_mark_load_complete: BU_TOP_LEVEL_MODULE is not set"
        A binary entrypoint forgot to export BU_TOP_LEVEL_MODULE before sourcing
        bu_entrypoint.sh.

${BU_TPUT_BOLD}SEE ALSO${BU_TPUT_RESET}
    bu get-command          list commands and their properties
    bu get-config           list configuration settings
    bu get-cache            list cached project registries
    docs/how_to_02_workflow.md   the project-dependency walkthrough
EOF
