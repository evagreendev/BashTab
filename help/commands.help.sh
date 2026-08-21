# Synopsis: BashTab's command discovery, registration, and dispatch

# Live checks. This file is sourced in a subshell by `bu get-help`, so plain
# assignments here cannot leak into the invoking shell.

_command_count=${#BU_COMMANDS[@]}
_verb_count=${#BU_COMMAND_VERBS[@]}
_noun_count=${#BU_COMMAND_NOUNS[@]}
_namespace_count=0
for _ns in "${!BU_COMMAND_NAMESPACES[@]}"; do
    [[ -n "$_ns" ]] && ((_namespace_count++))
done

_multi_verbs=${BU_MULTI_WORD_VERBS:-convert-to convert-from}

_search_dirs=$(for _d in "${!BU_COMMAND_SEARCH_DIRS[@]}"; do
    printf '    %s\n' "$_d"
done | sort)

_cmd_table=$(bu_help_topic_commands_tagged commands "$BU_BUILTIN_COMMANDS_DIR/core")

cat <<EOF
${BU_TPUT_BOLD}NAME${BU_TPUT_RESET}
    commands — how BashTab discovers, registers, and dispatches commands

${BU_TPUT_BOLD}SYNOPSIS${BU_TPUT_RESET}
    bu get-command --verb get
    bu new-command --dir commands --name my-cmd
    bu get-verb

${BU_TPUT_BOLD}DESCRIPTION${BU_TPUT_RESET}
    A command is a script (or shell function) made invocable as
    ${BU_CLI_COMMAND_NAME} verb-noun. Discovery is recursive over the registered
    command-search directories; registration is explicit via bu_preinit_* calls
    in a module preinit; dispatch reads the script header and the command's
    declared type.

${BU_TPUT_BOLD}NAMING STYLES${BU_TPUT_RESET}
    A file name is converted to a command name by a naming style, chosen when
    registering a command directory:

        none            file name as-is (mycmd.sh → mycmd)
        prefix          namespace-verb-noun (my-get-status.sh → get-status)
        powershell      verb-namespace-noun (get-my-status.sh → get-status)
        prefix-keep     prefix style but keeps the namespace in the name
        powershell-keep powershell style but keeps the namespace in the name

    Verb/noun split honors BU_MULTI_WORD_VERBS (currently: $_multi_verbs), so
    convert-to-jsonl parses as verb=convert-to, noun=jsonl.

${BU_TPUT_BOLD}HEADERS${BU_TPUT_RESET}
    Script headers declare behavior; all are read from the first ~30 lines:

        # Synopsis: One-line description        → bu get-command, --help NAME
        # Dispatch: source | execute            → explicit dispatch intent
        # Help-Topic: <topic>                   → --help SEE ALSO back-reference
        # Fields: name value default ...        → pipeline field completion

${BU_TPUT_BOLD}DISPATCH TYPES${BU_TPUT_RESET}
        execute   a new process (script has the exec bit)
        source    sourced into the caller's shell (may mutate it)
        function  an in-shell shell function
        alias     a positional→named-argument expansion (see bu get-alias)

    A source command mutating the shell must declare # Dispatch: source; an
    exec-bit script with that declaration is warned about (invoking it directly
    would silently no-op its mutations).

${BU_TPUT_BOLD}THIS MACHINE${BU_TPUT_RESET}
    registered commands:  $_command_count
    verbs / nouns:        $_verb_count / $_noun_count
    namespaces:           $_namespace_count
    command-search dirs:

$_search_dirs

${BU_TPUT_BOLD}COMMANDS${BU_TPUT_RESET}
    Derived from commands/core/ — only files tagged # Help-Topic: commands:

$_cmd_table

${BU_TPUT_BOLD}TYPICAL FLOWS${BU_TPUT_RESET}
    Enumerate the registry as records:
        bu get-command --format jsonl

    Find commands by verb/noun/namespace/type:
        bu get-command --verb get --type source
        bu get-command --namespace pipeline

    Scaffold a command (executable, source, or source-isolated):
        bu new-command --dir commands --name deploy
        bu new-command --dir commands --name setup --source
        bu new-command --dir commands --name peek --source-isolated

${BU_TPUT_BOLD}FAILURE SIGNATURES${BU_TPUT_RESET}
    "Command[foo] at '...' has no exec bit and no '# Dispatch: source' ..."
        A non-executable script without an explicit dispatch declaration is
        being sourced into the caller's shell. Add # Dispatch: source if that
        is intended, or chmod +x it to run as a separate process.

    Command missing from bu get-command
        Its directory is not in BU_COMMAND_SEARCH_DIRS (register it from a
        preinit), or its file name is skipped (__*, functions.*, overrides*,
        dotfiles, README).

    Tab completion offers nothing for a new command
        The command registry was scanned before the command existed. Run
        bu clear-cache <module> and re-activate, or re-source the init.

${BU_TPUT_BOLD}SEE ALSO${BU_TPUT_RESET}
    bu get-module           list loaded modules
    bu get-alias            list CLI aliases
    bu get-config           list configuration settings
    docs/how_to_01_create_custom_commands.md   the command-authoring guide
EOF
