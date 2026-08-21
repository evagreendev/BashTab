# Synopsis: BashTab's named locations, repos, and directory stack

# Live checks. This file is sourced in a subshell by `bu get-help`, so plain
# assignments here cannot leak into the invoking shell.

_local_file=${BU_LOCATION_LOCAL_FILE:-"$BU_DIR"/config/bu_locations_local.sh}
_location_count=${#BU_LOCATION_REGISTRY[@]}
_repo_count=$(bu_location_names --tag repo 2>/dev/null | grep -c . || true)

_names=$(bu_location_names --with-aliases 2>/dev/null | sed 's/^/    /')
[[ -n "$_names" ]] || _names="    (none registered)"

_cmd_table=$(bu_help_topic_commands_tagged locations \
    "$BU_BUILTIN_COMMANDS_DIR/core" \
    "$BU_BUILTIN_COMMANDS_DIR/shell" \
    "$BU_BUILTIN_COMMANDS_DIR/git")

cat <<EOF
${BU_TPUT_BOLD}NAME${BU_TPUT_RESET}
    locations — named locations, repos, and the directory stack

${BU_TPUT_BOLD}SYNOPSIS${BU_TPUT_RESET}
    bu new-location myproj --path '\$HOME/src/myproj' --alias mp
    bu set-location myproj
    bu get-location-registry

${BU_TPUT_BOLD}DESCRIPTION${BU_TPUT_RESET}
    A location is a name → target, where the target is either a lazily-expanded
    path expression or a resolver function. Think PowerShell goto shortcuts:
    bu set-location NAME cds to a registered target in the current shell.

    A repo is just a location (kind dir) plus git identity — not a parallel
    registry — so bu get-repo and the PR/ref helpers see the same names.

${BU_TPUT_BOLD}KINDS & PATH EXPRESSIONS${BU_TPUT_RESET}
    Kinds: dir (default), file, multi. Path expressions are stored UNexpanded
    and single-quoted so lazy \$VAR references survive re-sourcing and resolve
    against THIS shell each time:

        bu new-location build --path '\$MY_PROJECT_DIR/build'

    A path expression may only contain \$VAR parameter expansion; command
    substitution, backticks, and shell metacharacters are rejected at
    registration time (a path typo must never run code). For computed targets,
    register a --resolver FN instead. Locations may carry --alias, --tags,
    --description, and a dir-kind --on-enter hook run after cd.

${BU_TPUT_BOLD}PERSISTENCE${BU_TPUT_RESET}
    bu new-location writes a managed block into:

        $_local_file

    which is sourced after module preinits on every activation, so user
    locations override code defaults (last write wins). Resolver-based entries
    belong in code, not this file — bu new-location requires --path.

${BU_TPUT_BOLD}REPOS${BU_TPUT_RESET}
    bu new-location NAME --repo --path '...' --gh-slug owner/repo registers a
    repo (kind dir, tagged "repo") with git identity. bu get-repo renders the
    fleet as records: path, exists, branch, dirty, ahead/behind, remote_url,
    gh_slug, default_branch.

${BU_TPUT_BOLD}DIRECTORY STACK${BU_TPUT_RESET}
    bu push-location / bu pop-location / bu get-location-stack wrap the pushd/
    popd directory stack so well-known directories compose with cd navigation.

${BU_TPUT_BOLD}THIS MACHINE${BU_TPUT_RESET}
    local file:        $_local_file
    locations:         $_location_count   (repos: $_repo_count)
    registered names:

$_names

${BU_TPUT_BOLD}COMMANDS${BU_TPUT_RESET}
    Derived from core/shell/git command dirs — files tagged # Help-Topic: locations:

$_cmd_table

${BU_TPUT_BOLD}TYPICAL FLOWS${BU_TPUT_RESET}
    Jump to a project:
        bu set-location myproj

    Add a repo shortcut and inspect the fleet:
        bu new-location myrepo --path '\$HOME/src/myrepo' --repo --gh-slug owner/repo
        bu get-repo

    Drive navigation with the stack:
        bu push-location /tmp
        bu set-location myproj
        bu pop-location

${BU_TPUT_BOLD}FAILURE SIGNATURES${BU_TPUT_RESET}
    "Unknown location[name] (list with: bu get-location-registry)"
        The name (or alias) is not registered. List names with
        bu get-location-registry, or add one with bu new-location.

    "location[name] directory missing[...] (registered in ...)"
        The registered target does not exist on THIS machine. Re-point it with
        bu new-location or remove it.

    "--path contains forbidden characters (\$(, backtick, ;, &, |, <, >, newline)"
        A path expression tried to smuggle code execution. Use only \$VAR
        expansion, or a --resolver function for computed targets.

    "location[name] is kind[file], not [dir]"
        bu set-location only cds into dir locations. Use bu_location_resolve
        (or a kind:name sibling) for file/multi targets.

${BU_TPUT_BOLD}SEE ALSO${BU_TPUT_RESET}
    bu get-command          list commands and their properties
    bu get-config           list configuration settings
    lib/core/bu_core_location.sh   the location registry implementation
EOF
