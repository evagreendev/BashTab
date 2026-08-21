# Synopsis: BashTab's CLI aliases and shell aliases

# Live checks. This file is sourced in a subshell by `bu get-help`, so plain
# assignments here cannot leak into the invoking shell.

_cli_alias_count=0
for _c in "${!BU_COMMANDS[@]}"; do
    [[ "${BU_COMMAND_PROPERTIES[$_c,type]:-}" == alias ]] && ((_cli_alias_count++))
done

_shell_alias_count=$(alias 2>/dev/null | grep -c . || true)

_cmd_table=$(bu_help_topic_commands_tagged aliases \
    "$BU_BUILTIN_COMMANDS_DIR/core" \
    "$BU_BUILTIN_COMMANDS_DIR/shell")

cat <<EOF
${BU_TPUT_BOLD}NAME${BU_TPUT_RESET}
    aliases — BashTab's CLI aliases and shell aliases

${BU_TPUT_BOLD}SYNOPSIS${BU_TPUT_RESET}
    bu_preinit_register_new_alias gc get-command --namespace {} {?} --verb {} {?} --noun {} {...}
    bu get-alias
    bu set-alias ll 'ls -la'

${BU_TPUT_BOLD}DESCRIPTION${BU_TPUT_RESET}
    Two distinct alias systems coexist:

      CLI aliases     positional→named-argument expansions of other bu commands,
                      declared with bu_preinit_register_new_alias and listed by
                      bu get-alias (type alias in bu get-command).
      Shell aliases   the bash alias builtin, wrapped as structured records by
                      bu set-alias / bu remove-alias / bu get-shell-alias.

${BU_TPUT_BOLD}CLI ALIAS SPEC${BU_TPUT_RESET}
    An alias spec is the target command plus placeholder tokens:

        {}      one positional argument
        {...}   all remaining arguments
        {?}     consume one argument only if more remain (optional)

    Rules: at most one {...}, nothing after it, and {...} must be last-ish.
    The built-in examples show the pattern:

        gc    → get-command --namespace {} {?} --verb {} {?} --noun {} {...}
        where → query-object --where {...}
        select→ query-object --select {...}
        grep  → query-object --grep {...}
        sort  → query-object --order-by {...}

    So \`bu gc cmd source\` expands to
    \`bu get-command --namespace cmd --verb source\`, and
    \`bu where '.type == "source"'\` becomes \`bu query-object --where '...'\`.

${BU_TPUT_BOLD}SHELL ALIASES${BU_TPUT_RESET}
    bu set-alias wraps the alias builtin but emits structured records and reads
    pipeline input from bu get-shell-alias:

        bu set-alias ll 'ls -la'
        bu get-shell-alias | bu set-alias
        bu get-shell-alias | bu where '.name == "ll"'

${BU_TPUT_BOLD}THIS MACHINE${BU_TPUT_RESET}
    CLI aliases:      $_cli_alias_count
    shell aliases:    $_shell_alias_count

    List them: bu get-alias | bu get-shell-alias

${BU_TPUT_BOLD}COMMANDS${BU_TPUT_RESET}
    Derived from core/shell command dirs — files tagged # Help-Topic: aliases:

$_cmd_table

${BU_TPUT_BOLD}TYPICAL FLOWS${BU_TPUT_RESET}
    See what a CLI alias expands to:
        bu get-alias gc

    Declare a project-specific alias in a module preinit:
        bu_preinit_register_new_alias deploy-env import-environment -c ./commands {}

    Round-trip shell aliases as records:
        bu get-shell-alias | bu set-alias --what-if

${BU_TPUT_BOLD}FAILURE SIGNATURES${BU_TPUT_RESET}
    "Bad alias spec, there should not be another {...}"
        More than one {...} placeholder. An alias may consume "the rest" at
        most once.

    "Bad alias spec, there should not be {} after a {...}"
        A {} appeared after {...}, which would be unreachable.

    "Processing of alias[foo] failed"
        The alias target is not a registered command, or the expansion
        produced an invalid invocation.

${BU_TPUT_BOLD}SEE ALSO${BU_TPUT_RESET}
    bu get-command          list commands (aliases are type alias)
    bu get-module           list loaded modules
    lib/core/bu_core_preinit.sh   bu_preinit_register_new_alias
EOF
