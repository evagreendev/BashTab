#!/usr/bin/env bash
function __bu_bu_get_apk_package_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
# Exit 0 if this command can run on the current system, non-zero otherwise.
# stderr becomes the reason shown in `bu` help.
if [[ "$1" == "--is-compatible" ]]; then
    command -v apk &>/dev/null || { echo "apk is required" >&2; exit 1; }
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
if bu_env_is_in_autocomplete
then
    bu_autocomplete
    return 0
fi

if "$is_help"
then
    bu_autohelp \
        --description "List installed APK packages as structured records.

Wraps apk info -v to list installed Alpine Linux packages.  Each line
(name-version) is split into separate name and version fields." \
        --example "Default" ""
    return 0
fi

# apk info -v outputs "name-version" per line.
# Split into name and version: version is everything after the first
# dash that's followed by a digit (e.g. "busybox-1.36.1-r29").
{
    apk info -v 2>/dev/null | while IFS= read -r line; do
        local name version
        name=$(echo "$line" | sed -E 's/-[0-9].*$//')
        version=${line#"$name-"}
        printf '%s\t%s\n' "$name" "$version"
    done
} | bu_out_from_tsv --columns name,version \
  | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_get_apk_package_main "$@"
