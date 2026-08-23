# Synopsis: The gitshelf demo module — a "repo shelf" tool

# Live values. This file is sourced in a subshell by `bu get-help`, so plain
# assignments here cannot leak into the invoking shell. Compute dynamic facts
# up front, then interpolate them into the heredoc below.

_config=${GITSHELF_CONFIG_FILE:-"$GITSHELF_DIR/config/shelf.json"}
_cli=${BU_CLI_COMMAND_NAME:-bu}
_repo_count=$(jq -r '.repos | length' "$_config" 2>/dev/null || echo 0)
_cmd_table=$(bu_help_topic_commands "$GITSHELF_DIR/commands")

cat <<EOF
${BU_TPUT_BOLD}NAME${BU_TPUT_RESET}
    gitshelf — a tiny "repo shelf": track a set of local git repositories in
    one config file and survey them as a JSONL stream.

${BU_TPUT_BOLD}SYNOPSIS${BU_TPUT_RESET}
    $_cli get-repo
    $_cli get-repo --format table
    $_cli get-repo | $_cli query-object where dirty -eq true select name,branch
    $_cli add-repo --path ~/src/new-thing --tag shell
    $_cli remove-repo --name new-thing
    $_cli sync-repo --dry-run

${BU_TPUT_BOLD}DESCRIPTION${BU_TPUT_RESET}
    gitshelf is the canonical BashTab demo module. Its domain is deliberately
    boring so that every design decision showcases the module system rather
    than the problem:

        - binary mode:  \`source examples/gitshelf/activate\` gives a
          standalone \`shelf\` CLI in a fresh shell
        - library mode: a host project sources gitshelf_bu_module.sh and its
          commands appear alongside the host's own under one registry and one
          cache key

    The config file joins static facts (name, path, tags, comment) with live
    state probed from each working tree (branch, dirty, ahead/behind). Every
    command emits JSONL, so the shelf composes with the rest of the pipeline.

${BU_TPUT_BOLD}THIS MACHINE${BU_TPUT_RESET}
    config file:   $_config
    tracked repos: $_repo_count
    commands dir:  ${GITSHELF_STATE[commands_dir]:-}
    module state:  version=${GITSHELF_STATE[version]:-}

${BU_TPUT_BOLD}COMMANDS${BU_TPUT_RESET}
    Derived from examples/gitshelf/commands/:

$_cmd_table

${BU_TPUT_BOLD}TYPICAL FLOWS${BU_TPUT_RESET}
    Survey everything:
        $_cli get-repo --format table

    Pipe into a query (field completion knows the record schema):
        $_cli get-repo | $_cli query-object where dirty -eq true select name,branch

    Add a repo, then remove it:
        $_cli add-repo --path ~/src/myproject --tag shell
        $_cli remove-repo --name myproject

    Preview a sync without touching the network:
        $_cli sync-repo --dry-run

${BU_TPUT_BOLD}FAILURE SIGNATURES${BU_TPUT_RESET}
    "config file not found: ..."
        GITSHELF_CONFIG_FILE points at a missing file. Set it (or restore
        examples/gitshelf/config/shelf.json).

    "Unknown repo[name]"
        --name/--tag matched nothing in the config. Run \`$_cli get-repo\` to
        see the tracked names.

    "Repo[name] already exists in ..."
        add-repo refuses to overwrite an existing entry. remove-repo first.

    "jq is required" / "git is required"
        The command's --is-compatible probe failed, so it was never registered
        on this host.

${BU_TPUT_BOLD}SEE ALSO${BU_TPUT_RESET}
    $_cli get-module           list loaded modules (gitshelf should appear)
    $_cli get-help modules     the module-system topic
    $_cli get-command          list commands and their output fields
    examples/gitshelf/README.md   the walkthrough (binary vs library mode)
EOF
