#!/usr/bin/env bash
function __bu_bu_get_rpm_package_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
# Exit 0 if this command can run on the current system, non-zero otherwise.
# stderr becomes the reason shown in `bu` help.
if [[ "$1" == "--is-compatible" ]]; then
    command -v rpm &>/dev/null || { echo "rpm is required" >&2; exit 1; }
    exit 0
fi

local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local is_help=false
local format=auto
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
    -h|--help)# _FLAG
        is_help=true
        ;;
    *)
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
local remaining_options=("$@")
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi

if "$is_help"
then
    bu_autohelp \
        --description "List installed RPM packages as structured records.

Wraps rpm -qa --queryformat to produce TSV output, then pipes through
the standard BashTab structured-output pipeline.  Works on Fedora, RHEL,
CentOS, openSUSE, and any RPM-based distribution." \
        --example "Default" ""
    return 0
fi

{
    rpm -qa --queryformat '%{NAME}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{SUMMARY}\n' 2>/dev/null
} | bu_out_from_tsv --columns name,version,release,arch,summary \
  | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_get_rpm_package_main "$@"
