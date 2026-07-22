#!/usr/bin/env bash
function __bu_bu_get_openrc_service_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
if [[ "$1" == "--is-compatible" ]]; then
    command -v rc-status &>/dev/null || { echo "rc-status is required (OpenRC)" >&2; exit 1; }
    exit 0
fi

local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local is_help=false
local format=auto
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --format)# FORMAT
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
    if "$is_help"; then break; fi
    if (( $# < shift_by )); then bu_parse_error_argn "$1" $#; break; fi
    shift "$shift_by"
done
if bu_env_is_in_autocomplete; then bu_autocomplete; return 0; fi

if "$is_help"; then
    bu_autohelp \
        --description "List OpenRC services and their status as structured records.

Wraps rc-status and parses the output.  Works on Alpine Linux, Gentoo,
and any OpenRC-based distribution." \
        --example "Default" ""
    return 0
fi

# rc-status output format:
#   Runlevel: default
#    sshd              [ started ]
#    nginx             [ stopped ]
# Parse: skip runlevel headers, extract service name and bracketed status.
{
    rc-status 2>/dev/null | while IFS= read -r line; do
        # Skip runlevel headers and empty lines
        [[ -z "$line" || "$line" == Runlevel:* ]] && continue
        # Extract: everything before "[" is service name (trimmed),
        #          content inside [ ] is status
        local service status
        service=$(echo "$line" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*\[.*//')
        status=$(echo "$line" | sed -E 's/.*\[[[:space:]]*([^]]*)[[:space:]]*\].*/\1/')
        printf '%s\t%s\n' "$service" "$status"
    done
} | bu_out_from_tsv --columns service,status \
  | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_get_openrc_service_main "$@"
