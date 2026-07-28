#!/usr/bin/env bash
function __bu_bu_get_git_branch_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
# Exit 0 if this command can run on the current system, non-zero otherwise.
# stderr becomes the reason shown in `bu` help.
if [[ "$1" == "--is-compatible" ]]; then
    command -v git &>/dev/null || { echo "git is required" >&2; exit 1; }
    git rev-parse --git-dir &>/dev/null || { echo "not inside a git repository" >&2; exit 1; }
    exit 0
fi
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local is_help=false
local format=auto
local is_all=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --format)# FORMAT
        # Output format
        bu_parse_positional $# --enum ${BU_OUT_FORMATS[@]} enum-- --hint "Output format"
        format=${!shift_by}
        ;;
    -a|--all)# _FLAG
        # Include remote-tracking branches
        is_all=true
        ;;
    -h|--help)# _FLAG
        is_help=true
        ;;
    *)
        bu_parse_error_enum "$1"
        break
        ;;
    esac
    if "$is_help"
    then
        break
    fi
    if (( $# < shift_by ))
    then
        bu_parse_error_argn "$1" $#
        break
    fi
    shift "$shift_by"
done
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi

if "$is_help"
then
    bu_autohelp \
        --description "
List git branches as structured records (git for-each-ref, no pager).
Each record: name, current (boolean), commit, upstream, track (ahead/behind),
date, subject. Sorted by most recent commit first.
" \
        --example "Local branches" "" \
        --example "Including remotes" "--all"
    return 0
fi

local -a ref_patterns=(refs/heads)
"$is_all" && ref_patterns+=(refs/remotes)

# TSV per branch; current marker comes from %(HEAD)
git for-each-ref "${ref_patterns[@]}" --sort=-committerdate \
    --format='%(refname:short)%09%(HEAD)%09%(objectname:short)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:iso8601)%09%(subject)' \
    2>/dev/null \
    | bu_out_from_tsv --columns name,head,commit,upstream,track,date,subject \
    | jq -c '.current = (.head == "*") | del(.head) | .upstream |= (if . == "" then null else . end) | .track |= (if . == "" then null else . end)' \
    | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_get_git_branch_main "$@"
