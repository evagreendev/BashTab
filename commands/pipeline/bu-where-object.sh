#!/usr/bin/env bash
# Dispatch: source
# Synopsis: Filter a JSONL stream with a jq boolean expression
function __bu_bu_where_object_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local expression=
local format=auto
local is_help=false
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
        # Print help
        is_help=true
        ;;
    *)
        if [[ -n "$expression" ]]
        then
            bu_parse_error_enum "$1"
        elif [[ "$1" == .* || "$1" == \(* || "$1" == select\(* ]]
        then
            # Raw jq expression (backward compatible)
            if bu_env_is_in_autocomplete; then
                autocompletion=(--hint "jq expression" --pipeline-fields --dot pipeline-fields--)
            fi
            expression=$1
        elif [[ "$1" != -* ]]
        then
            # Structured comparison with optional and/or chaining.
            # Grammar: field -op [val] { and|or field -op [val] }*
            local -a _ws_segments=()
            local -a _ws_connectors=()
            local _ws_extra=0
            local _ws_field=$1
            local _ws_complete=false
            if bu_env_is_in_autocomplete; then
                autocompletion=(--hint "Field name" --pipeline-fields pipeline-fields--)
            fi

            while true; do
                # Parse operator for current field
                local _ws_op= _ws_val= _ws_cond_consume=0
                local _ws_o_idx=$(( 1 + _ws_extra + 1 ))  # +1 for shift_by base
                if (( _ws_o_idx <= $# )); then
                    local _ws_o_arg=${!_ws_o_idx}
                    case "$_ws_o_arg" in
                    -eq|-ne|-gt|-lt|-ge|-le|-like|-notlike|-match|-notmatch|-contains|-notcontains|-in|-notin)
                        _ws_op=$_ws_o_arg; _ws_cond_consume=1
                        local _ws_v_idx=$(( 1 + _ws_extra + 2 ))
                        if (( _ws_v_idx <= $# )); then
                            local _ws_v_arg=${!_ws_v_idx}
                            if [[ "$_ws_v_arg" != -* ]] || [[ "$_ws_v_arg" =~ ^-[0-9] ]]; then
                                _ws_val=$_ws_v_arg; _ws_cond_consume=2
                            fi
                        fi
                        ;;
                    -isnull|-isnotnull)
                        _ws_op=$_ws_o_arg; _ws_cond_consume=1
                        ;;
                    -*)
                        # Partial / unknown operator — don't consume.
                        :
                        ;;
                    esac
                fi
                _ws_extra=$((_ws_extra + _ws_cond_consume))

                if [[ -n "$_ws_op" ]]; then
                    if [[ "$_ws_op" != -isnull && "$_ws_op" != -isnotnull && -z "$_ws_val" ]]; then
                        if ! bu_env_is_in_autocomplete; then
                            error_msg="Missing value after operator[$_ws_op] for field[$_ws_field]"
                            bu_autohelp; bu_scope_pop_function; return 1
                        fi
                        _ws_complete=false; break
                    fi
                    local _ws_seg_jq
                    _ws_seg_jq=$(__bu_query_object_translate_op "$_ws_field" "$_ws_op" "$_ws_val") || {
                        error_msg="Invalid where clause: $_ws_field $_ws_op $_ws_val"
                        bu_autohelp; bu_scope_pop_function; return 1
                    }
                    _ws_segments+=("$_ws_seg_jq")
                    _ws_complete=true
                else
                    _ws_complete=false; break
                fi

                # Check for and/or connector
                local _ws_c_idx=$(( 1 + _ws_extra + 1 ))
                if (( _ws_c_idx > $# )); then break; fi
                local _ws_c_arg=${!_ws_c_idx}
                case "$_ws_c_arg" in
                and|or)
                    _ws_connectors+=("$_ws_c_arg")
                    _ws_extra=$((_ws_extra + 1))
                    ;;
                *)
                    break
                    ;;
                esac

                # Parse next field name
                local _ws_f_idx=$(( 1 + _ws_extra + 1 ))
                if (( _ws_f_idx > $# )); then
                    _ws_complete=false; break
                fi
                _ws_field=${!_ws_f_idx}
                if [[ "$_ws_field" == -* ]]; then
                    if ! bu_env_is_in_autocomplete; then
                        error_msg="Expected field name after '${_ws_connectors[-1]}', got flag[$_ws_field]"
                        bu_autohelp; bu_scope_pop_function; return 1
                    fi
                    _ws_extra=$((_ws_extra - 1))
                    unset '_ws_connectors[-1]'
                    _ws_complete=true; break
                fi
                _ws_extra=$((_ws_extra + 1))
                _ws_complete=false
            done

            : $((shift_by += _ws_extra))

            # Consume trailing empty/operator-like arg (same fix as query-object)
            if (( shift_by < $# )); then
                local _ws_tail_idx=$(( shift_by + 1 ))
                local _ws_tail=${!_ws_tail_idx}
                if [[ -z "$_ws_tail" || ( "$_ws_tail" == -* && "$_ws_tail" != --* ) ]]; then
                    : $((shift_by++))
                fi
            fi

            # Set autocomplete
            if [[ -z "$_ws_op" && -n "$_ws_field" ]] && (( $# > 1 )); then
                # Have a field name AND cursor is past it → show operators
                autocompletion=(--enum -eq -ne -gt -lt -ge -le -like -notlike -match -notmatch -contains -notcontains -in -notin -isnull -isnotnull enum-- --hint "Comparison operator")
            elif [[ -z "$_ws_op" && -z "$_ws_field" ]] && ((${#_ws_connectors[@]} > 0)); then
                autocompletion=(--hint "Field name (after ${_ws_connectors[-1]})" --pipeline-fields pipeline-fields--)
            elif [[ "$_ws_complete" == true ]]; then
                autocompletion=(--enum and or enum-- --hint "Logical connector (and/or)")
            elif [[ -n "$_ws_op" && -z "$_ws_val" && "$_ws_op" != -isnull && "$_ws_op" != -isnotnull ]]; then
                autocompletion=(--hint "Value for $_ws_field $_ws_op")
            fi
            if [[ -z "$_ws_op" && -z "$_ws_field" ]] && ((${#_ws_connectors[@]} == 0)); then
                autocompletion=(--hint "Field name" --pipeline-fields pipeline-fields--)
            fi

            # Build combined jq expression
            if ((${#_ws_segments[@]} > 0)); then
                local _ws_combined="${_ws_segments[0]}"
                local _ws_i
                for (( _ws_i = 1; _ws_i < ${#_ws_segments[@]}; _ws_i++ )); do
                    _ws_combined="($_ws_combined) ${_ws_connectors[_ws_i-1]} (${_ws_segments[_ws_i]})"
                done
                expression=$_ws_combined
            fi
        else
            bu_parse_error_enum "$1"
        fi
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
        --description "
Filter a JSONL stream (PowerShell Where-Object). Two syntaxes:
  Raw jq expression:   where-object '.type == \"source\"'
  Structured:           where-object type -eq source

Structured operators:
  -eq -ne -gt -lt -ge -le   scalar comparisons
  -like -notlike            glob pattern matching (*, ?); no wildcard implies *pattern* (substring)
  -match -notmatch          regex matching (RLIKE)
  -contains -notcontains    array contains value
  -in -notin                value in field
  -isnull -isnotnull        null checks

Chain conditions with `and`/`or`:
  where-object type -eq source and name -like get-*
  where-object name -like command   # substring: matches get-command, set-module, ...

The current record is '.' in jq expressions. Streams with O(1) latency.
" \
        --example "Only source commands (structured)" "type -eq source" \
        --example "Only source commands (jq)" "'.type == \"source\"'" \
        --example "Glob pattern match" "name -like get-*" \
        --example "Substring match (bare pattern)" "name -like command" \
        --example "Regex match (RLIKE)" "name -match '^get-'" \
        --example "And chaining" "type -eq source and name -like get-*" \
        --example "Or chaining" "type -eq source or type -eq alias"
    return 0
fi

if [[ -z "$expression" ]]
then
    error_msg="Missing required filter expression (e.g. bu where-object type -eq source)"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

# Cmdlets implicitly end at Out-Default: a table on a terminal, JSONL when piped
bu_out_where "$expression" | bu_out --format "$format"

bu_scope_pop_function
}

__bu_bu_where_object_main "$@"
