#!/usr/bin/env bash
function __bu_bu_query_object_main()
{
local -r invocation_dir=$PWD

# shellcheck source=./__bu_entrypoint_decl.sh
source "$BU_NULL"

bu_scope_push_function
bu_run_log_command "$@"

local select_fields=
local -a where_exprs=()
local group_keys=
local -a agg_specs=()
local -a having_exprs=()
local order_by=
local is_desc=false
local is_distinct=false
local first=
local format=auto
local columns=
local is_debug=false
local is_help=false
local error_msg=
local autocompletion=()
local shift_by=
while (($#))
do
    bu_parse_multiselect $# "$1"
    case "$1" in
    --select|select)# SELECT
        # Fields to keep, in order (comma-separated; new=old renames)
        bu_parse_positional $# --ret __bu_out_complete_pipeline_fields ret-- --hint "Fields (from pipeline producer), new=old renames"
        select_fields=${!shift_by}
        ;;
    --where|where)# WHERE
        # Filter records with a jq boolean expression. Repeatable; multiple
        # expressions are ANDed together.
        bu_parse_positional $# --ret __bu_out_complete_pipeline_fields --dot ret-- --hint "jq boolean expression"
        where_exprs+=("${!shift_by}")
        ;;
    --group-by|group-by)# GROUP_BY
        # Group records by key fields (comma-separated), collapsing each group
        # into one record. Use agg to add aggregates; no agg emits distinct keys.
        bu_parse_positional $# --ret __bu_out_complete_pipeline_fields ret-- --hint "Group key fields (from pipeline producer)"
        group_keys=${!shift_by}
        ;;
    --agg|agg)# AGG
        # Aggregates for group-by: [name=]func[:field], comma-separated and/or
        # repeatable. funcs: count, sum, avg, min, max, first, last, collect
        bu_parse_positional $# --enum count sum avg min max first last collect enum-- --hint "Aggregates: [name=]func[:field]"
        local agg_spec
        local ifs=$IFS
        IFS=','
        # shellcheck disable=SC2206 # Intentional word splitting on commas
        for agg_spec in ${!shift_by}; do [[ -n "$agg_spec" ]] && agg_specs+=("$agg_spec"); done
        IFS=$ifs
        ;;
    --having|having)# HAVING
        # Filter groups after group-by (jq expression on group/aggregate fields).
        # Repeatable; multiple expressions are ANDed together.
        bu_parse_positional $# --ret __bu_out_complete_pipeline_fields --dot ret-- --hint "jq boolean expression (group fields)"
        having_exprs+=("${!shift_by}")
        ;;
    --order-by|order-by)# ORDER_BY
        # Field to sort by (refers to output field names, after any renames)
        bu_parse_positional $# --ret __bu_out_complete_pipeline_fields ret-- --hint "Sort field (from pipeline producer)"
        order_by=${!shift_by}
        ;;
    --desc|desc)# _FLAG
        # Sort descending
        is_desc=true
        ;;
    --distinct|distinct)# _FLAG
        # Remove duplicate records (SELECT DISTINCT). Runs after select:
        # records are deduped as a whole, first occurrence wins.
        is_distinct=true
        ;;
    --first|first)# FIRST
        # Take only the first N records (after sorting)
        bu_parse_positional $# --hint "Number of records"
        first=${!shift_by}
        ;;
    --format)# FORMAT
        # Output format
        bu_parse_positional $# --enum ${BU_OUT_FORMATS[@]} enum-- --hint "Output format"
        bu_validate_positional "${!shift_by}"
        format=${!shift_by}
        ;;
    --columns)# COLUMNS
        # Display columns as key:Label (comma-separated). Forwarded to table/list/tsv.
        bu_parse_positional $# --ret __bu_out_complete_pipeline_fields ret-- --hint "Comma-separated columns, key:Label renames headers"
        columns=${!shift_by}
        ;;
    -h|--help)# _FLAG
        # Print help
        is_help=true
        ;;
    --debug)# _FLAG
        # Output a JSON query plan describing what this query would do
        # (clauses and output field names) without reading stdin.
        # Used by the pipeline completion system for static analysis.
        is_debug=true
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
Query a JSONL stream with SQL-style clauses in a single command.
Clauses may be given in any order; execution always follows SQL logical
order: WHERE -> GROUP BY -> HAVING -> SELECT -> ORDER BY -> FIRST.

  where     uses source field names  (jq expression, repeatable, ANDed)
  group-by  collapses records by key fields (comma-separated composite key)
  agg       aggregates per group: [name=]func[:field], repeatable and/or
            comma-separated. funcs: count, sum, avg, min, max, first, last, collect
  having    filters groups, uses group/aggregate field names
  select    projects/reorders/renames fields (new=old)
  distinct  removes duplicate records after projection (SELECT DISTINCT)
  order-by  uses output field names  (after renames, like SQL aliases)
  first     takes the first N records (SQL LIMIT)

Each clause keyword works with or without dashes (select / --select).
Output ends at Out-Default: a table on a terminal, JSONL when piped.
" \
        --example "Full query" "where '.type == \"source\"' select name,verb order-by verb" \
        --example "Any clause order" "order-by noun select name,noun where '.namespace == \"bu\"'" \
        --example "Rename then order by the alias" "select name,ver=version order-by ver" \
        --example "Top 3" "order-by name first 3" \
        --example "Distinct projected fields" "select verb distinct" \
        --example "Group and count" "group-by verb agg count" \
        --example "Group with aggregates and having" "group-by verb agg count,avg:len having '.count > 1' order-by count desc" \
        --example "Dashed forms work too" "--where '.type == \"source\"' --select name"
    return 0
fi

# Compose the clauses into a pipeline in SQL logical order, using identity
# stages (cat) for absent clauses so no eval or string assembly is needed.
local where_expr=
if ((${#where_exprs[@]} > 0))
then
    where_expr="(${where_exprs[0]})"
    local w
    for w in "${where_exprs[@]:1}"
    do
        where_expr+=" and ($w)"
    done
fi

if [[ -n "$first" && ! "$first" =~ ^[0-9]+$ ]]
then
    error_msg="--first expects a non-negative integer, got[$first]"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

if [[ -z "$group_keys" ]] && ((${#agg_specs[@]} > 0))
then
    error_msg="agg requires group-by (e.g. bu query-object group-by verb agg count)"
    bu_autohelp
    bu_scope_pop_function
    return 1
fi

local having_expr=
if ((${#having_exprs[@]} > 0))
then
    having_expr="(${having_exprs[0]})"
    local h
    for h in "${having_exprs[@]:1}"
    do
        having_expr+=" and ($h)"
    done
fi

if "$is_debug"
then
    # --debug: emit a JSON query plan describing clauses and output fields.
    # Used by the pipeline completion system for static field analysis.
    # Does not read stdin.
    local -a clauses=()
    local -a output_fields=()

    [[ -n "$where_expr" ]] && clauses+=(where)
    [[ -n "$group_keys" ]] && clauses+=(group-by)
    ((${#agg_specs[@]} > 0)) && clauses+=(agg)
    [[ -n "$having_expr" ]] && clauses+=(having)
    [[ -n "$select_fields" ]] && clauses+=(select)
    "$is_distinct" && clauses+=(distinct)
    [[ -n "$order_by" ]] && clauses+=(order-by)

    # Compute output field names
    if [[ -n "$select_fields" ]]
    then
        # SELECT projects: output fields are the select spec names (after rename)
        local sel_spec sel_new
        local ifs=$IFS
        IFS=','
        for sel_spec in $select_fields
        do
            [[ -z "$sel_spec" ]] && continue
            case "$sel_spec" in
            *=*) sel_new=${sel_spec%%=*} ;;
            *)   sel_new=$sel_spec ;;
            esac
            output_fields+=("$sel_new")
        done
        IFS=$ifs
    elif [[ -n "$group_keys" ]]
    then
        # GROUP BY without SELECT: output fields = group keys + aggregate names
        local gk
        local ifs=$IFS
        IFS=','
        for gk in $group_keys; do [[ -n "$gk" ]] && output_fields+=("$gk"); done
        IFS=$ifs
        local agg_spec agg_name agg_body agg_func agg_field
        for agg_spec in "${agg_specs[@]}"
        do
            case "$agg_spec" in
            *=*) agg_name=${agg_spec%%=*}; agg_body=${agg_spec#*=} ;;
            *)   agg_name=; agg_body=$agg_spec ;;
            esac
            agg_func=${agg_body%%:*}
            agg_field=${agg_body#*:}
            [[ "$agg_field" == "$agg_body" ]] && agg_field=
            [[ -z "$agg_name" ]] && agg_name=$agg_func${agg_field:+_$agg_field}
            output_fields+=("$agg_name")
        done
    fi

    local clauses_json
    clauses_json=$("$BU_OUT_JQ" -cn --args '$ARGS.positional' -- "${clauses[@]}")
    local fields_json
    if ((${#output_fields[@]} > 0))
    then
        fields_json=$("$BU_OUT_JQ" -cn --args '$ARGS.positional' -- "${output_fields[@]}")
    else
        fields_json=null
    fi

    "$BU_OUT_JQ" -cn --argjson clauses "$clauses_json" --argjson fields "$fields_json" \
        '{clauses: $clauses, outputFields: $fields}'
    bu_scope_pop_function
    return 0
fi

__bu_query_object_where()
{
    if [[ -n "$where_expr" ]]
    then
        bu_out_where "$where_expr"
    else
        cat
    fi
}

__bu_query_object_group()
{
    if [[ -n "$group_keys" ]]
    then
        local -a group_args=(--keys "$group_keys")
        local spec
        for spec in "${agg_specs[@]}"
        do
            group_args+=(--agg "$spec")
        done
        bu_out_group_by "${group_args[@]}"
    else
        cat
    fi
}

__bu_query_object_having()
{
    if [[ -n "$having_expr" ]]
    then
        bu_out_where "$having_expr"
    else
        cat
    fi
}

__bu_query_object_select()
{
    if [[ -n "$select_fields" ]]
    then
        bu_out_select "$select_fields"
    else
        cat
    fi
}

__bu_query_object_distinct()
{
    if "$is_distinct"
    then
        bu_out_distinct
    else
        cat
    fi
}

__bu_query_object_sort()
{
    if [[ -n "$order_by" ]]
    then
        local -a sort_args=("$order_by")
        "$is_desc" && sort_args+=(--desc)
        bu_out_sort_by "${sort_args[@]}"
    else
        cat
    fi
}

__bu_query_object_first()
{
    if [[ -n "$first" ]]
    then
        head -n "$first"
    else
        cat
    fi
}

local -a out_args=(--format "$format")
[[ -n "$columns" ]] && out_args+=(--columns "$columns")

# Cmdlets implicitly end at Out-Default: a table on a terminal, JSONL when piped
__bu_query_object_where | __bu_query_object_group | __bu_query_object_having | __bu_query_object_select | __bu_query_object_distinct | __bu_query_object_sort | __bu_query_object_first | bu_out "${out_args[@]}"

bu_scope_pop_function
}

__bu_bu_query_object_main "$@"
