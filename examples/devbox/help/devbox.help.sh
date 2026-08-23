# Synopsis: The devbox host project — consuming gitshelf as a library

# Sourced in a subshell by `bu get-help`; assignments here cannot leak.

_cli=${BU_CLI_COMMAND_NAME:-bu}
_gitshelf_preinit=$(printf '%s\n' "$BU_MODULE_LIST" | tr ';' '\n' | grep '^gitshelf:' | head -n 1)
_cmd_table=$(bu_help_topic_commands "$DEVBOX_DIR/commands")

cat <<EOF
${BU_TPUT_BOLD}NAME${BU_TPUT_RESET}
    devbox — a tiny host project that consumes the gitshelf module as a
    library, demonstrating the library/binary duality of BashTab modules.

${BU_TPUT_BOLD}SYNOPSIS${BU_TPUT_RESET}
    $_cli get-env
    $_cli get-repo
    $_cli get-module

${BU_TPUT_BOLD}DESCRIPTION${BU_TPUT_RESET}
    devbox registers itself as the top-level module and then sources
    gitshelf_bu_module.sh (the LIBRARY entrypoint — never gitshelf/activate).
    The result is one command registry, one cache key, and one help system
    serving both projects' commands side by side.

    gitshelf library entry: $_gitshelf_preinit

${BU_TPUT_BOLD}THIS MACHINE${BU_TPUT_RESET}
    host module:  devbox
    cli name:     $_cli

${BU_TPUT_BOLD}COMMANDS${BU_TPUT_RESET}
    devbox's own commands:

$_cmd_table

    gitshelf's commands appear alongside these (run \`$_cli get-command\`).

${BU_TPUT_BOLD}TYPICAL FLOWS${BU_TPUT_RESET}
    Prove the host has its own commands:
        $_cli get-env

    Prove the library's commands are wired into the same registry:
        $_cli get-repo --format table

    Prove both modules are loaded under one cache key:
        $_cli get-module

${BU_TPUT_BOLD}SEE ALSO${BU_TPUT_RESET}
    $_cli get-help gitshelf      the library's own help page
    $_cli get-help modules       the module-system topic
    examples/devbox/README.md    the walkthrough
EOF
