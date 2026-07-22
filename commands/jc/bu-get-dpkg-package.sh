#!/usr/bin/env bash
function __bu_bu_get_dpkg_package_main()
{
# --is-compatible: magic flag checked by the framework at registration time.
# Exit 0 if this command can run on the current system, non-zero otherwise.
# stderr becomes the reason shown in `bu` help.
if [[ "$1" == "--is-compatible" ]]; then
    command -v dpkg &>/dev/null || { echo "dpkg is required" >&2; exit 1; }
    command -v jc &>/dev/null   || { echo "jc is required" >&2; exit 1; }
    if [[ -f /etc/os-release ]]; then
        local _id _id_like
        _id=$(grep -oP '^ID=\K.*' /etc/os-release | tr -d '"')
        _id_like=$(grep -oP '^ID_LIKE=\K.*' /etc/os-release | tr -d '"')
        case " $_id $_id_like " in
            *" debian "*|*" ubuntu "*) : ;;
            *) echo "requires Debian-based system" >&2; exit 1 ;;
        esac
    fi
    exit 0
fi

local -r invocation_dir=$PWD

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
        # Any unrecognized arg: pass through to the underlying command, replacing the default
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
        --description "List installed Debian packages (jc dpkg-l parser wrapper)." \
        --example "Default" "" \
        --example "With extra flags" "-- -la /var/log"
    return 0
fi

if ! command -v jc &>/dev/null
then
    error_msg="jc is required. Install with: pip install jc"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

# Build the command: use provided args if any, otherwise the default
local -a cmd=()
if ((${#remaining_options[@]} > 0))
then
    cmd=("${remaining_options[@]}")
else
    cmd=(dpkg -l)
fi

"${cmd[@]}" 2>/dev/null | jc --dpkg-l 2>/dev/null | jq -c 'if type == "array" then .[] else . end' 2>/dev/null | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_get_dpkg_package_main "$@"
