# MARK: Structured output
# PowerShell-inspired structured output for bu commands.
#
# Data model: JSONL (one JSON object per line) is the "object pipeline".
# Commands produce records, transforms pass them through, and a sink
# formatter decides presentation at the end of the pipeline (Out-Default).
#
# Layers:
# - Recordifiers (raw -> JSONL): bu_out_record, bu_out_from_tsv, bu_out_from_lines
# - Sinks (JSONL -> display):    bu_format_table, bu_format_list,
#                                bu_format_json, bu_format_jsonl, bu_format_tsv
# - Dispatcher (Out-Default):    bu_out
#
# jq is the backend for record construction and formatting.
# Pipeline users can drop to raw jq at any point for Where-Object /
# Select-Object style filtering.

if false; then
source ./bu_core_base.sh
fi

# Resolved once at source time. Empty means jq is unavailable.
BU_OUT_JQ=$(command -v jq 2>/dev/null) || BU_OUT_JQ=

# Static field registry: producer command-line prefix -> space-separated
# record fields. Consulted first by __bu_out_complete_pipeline_fields when
# completing after a pipe. Longest prefix match wins, so fields stay correct
# even when the producer carries flags or later pipeline stages.
# Extend via bu_register_output_fields (e.g. from a module preinit script).
declare -A -g BU_OUT_PRODUCER_FIELDS=(
    ["bu get-command"]="name verb noun namespace type"
    ["bu get-module"]="name version path"
)

# Allowlist of producer head commands that may be executed ("probed") during
# autocompletion to discover fields from live output. Probing runs the
# user-typed pipeline prefix, so both this allowlist and the master switch
# BU_OUT_PROBE_PIPELINE are opt-in. Example:
#     BU_OUT_PROBE_COMMANDS[kubectl]=1
declare -A -g BU_OUT_PROBE_COMMANDS=()

# ```
# *Description*:
# Assert that jq is available for structured output
#
# *Returns*:
# - Exit code 1 and logs an error if jq is not available
# ```
__bu_out_assert_jq()
{
    if [[ -z "$BU_OUT_JQ" ]]
    then
        bu_log_err "jq is required for bu structured output. Install jq (e.g. 'sudo apt install jq' / 'brew install jq')."
        return 1
    fi
}

# ```
# *Description*:
# Validate a record key. Keys become jq object keys in generated programs,
# so they must be plain identifiers.
#
# *Params*:
# - `$1`: Key to validate
#
# *Returns*:
# - Exit code 1 and logs an error if the key is invalid
# ```
__bu_out_validate_key()
{
    if [[ ! "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
    then
        bu_log_err "Invalid record key[$1]. Keys must match [a-zA-Z_][a-zA-Z0-9_]*"
        return 1
    fi
}

# ```
# *Description*:
# Parse a comma-separated column spec list, supporting optional display labels.
#
# *Params*:
# - `$1`: Comma-separated specs, each `key` or `key:Label`
#         (e.g. `name:Module,version,path:Location`). Empty string yields empty arrays.
#
# *Returns*:
# - `$BU_RET`: JSON array of keys (e.g. `["name","version","path"]`)
# - `$BU_RET_HEADERS`: JSON array of display labels, parallel to the keys
#                      (e.g. `["Module","version","Location"]`). Unlabeled keys
#                      use the key itself as the label.
#
# *Notes*:
# - Labels are display-only; lookups and --colors always use the key.
# - Keys must be identifiers (validated); labels may be any string.
# ```
__bu_out_parse_colspecs()
{
    local -a specs=()
    local spec
    local ifs=$IFS
    IFS=','
    # shellcheck disable=SC2206 # Intentional word splitting on commas
    specs=($1)
    IFS=$ifs
    local -a keys=() headers=()
    local key header
    for spec in "${specs[@]}"
    do
        [[ -z "$spec" ]] && continue
        key=${spec%%:*}
        header=${spec#*:}
        [[ -z "$header" ]] && header=$key
        __bu_out_validate_key "$key" || return 1
        keys+=("$key")
        headers+=("$header")
    done
    if ((${#keys[@]} == 0))
    then
        BU_RET='[]'
        BU_RET_HEADERS='[]'
    else
        BU_RET=$("$BU_OUT_JQ" -cn --args '$ARGS.positional' -- "${keys[@]}")
        BU_RET_HEADERS=$("$BU_OUT_JQ" -cn --args '$ARGS.positional' -- "${headers[@]}")
    fi
}

# ```
# *Description*:
# Convert a comma-separated column spec list to a JSON array of keys,
# silently dropping any `:Label` display labels.
#
# *Params*:
# - `$1`: Comma-separated specs (see __bu_out_parse_colspecs)
#
# *Returns*:
# - `$BU_RET`: JSON array of keys
# ```
__bu_out_cols_to_json()
{
    __bu_out_parse_colspecs "$@"
}

# ```
# *Description*:
# Convert a comma-separated column spec list to a JSON array of
# `{key, header}` objects for the display formatters.
#
# *Params*:
# - `$1`: Comma-separated specs (see __bu_out_parse_colspecs)
#
# *Returns*:
# - `$BU_RET`: JSON array (e.g. `[{"key":"name","header":"Module"},...]`)
# ```
__bu_out_colspecs_to_json()
{
    __bu_out_parse_colspecs "$@" || return 1
    local keys_json=$BU_RET
    if [[ "$keys_json" == '[]' ]]
    then
        BU_RET='[]'
        return 0
    fi
    BU_RET=$("$BU_OUT_JQ" -cn \
        --argjson keys "$keys_json" \
        --argjson headers "$BU_RET_HEADERS" \
        '[range(0; $keys | length) | {key: $keys[.], header: $headers[.]}]')
}

# ```
# *Description*:
# Build a JSON color map from a comma-separated `key=color` spec
#
# *Params*:
# - `$1`: Comma-separated `key=color` pairs (e.g. `name=green,version=yellow`).
#         Colors map to BU_TPUT_* variables (e.g. `green` -> `$BU_TPUT_GREEN`).
#
# *Returns*:
# - `$BU_RET`: JSON object mapping keys to ANSI codes (e.g. `{"name":"\u001b[32m"}`)
# ```
__bu_out_colors_to_json()
{
    local spec=$1
    BU_RET='{}'
    [[ -z "$spec" ]] && return 0

    local -a pairs=()
    local ifs=$IFS
    IFS=','
    # shellcheck disable=SC2206 # Intentional word splitting on commas
    pairs=($spec)
    IFS=$ifs

    local -a kv=()
    local pair key color_name color_var
    for pair in "${pairs[@]}"
    do
        [[ -z "$pair" ]] && continue
        key=${pair%%=*}
        color_name=${pair#*=}
        __bu_out_validate_key "$key" || return 1
        color_var=BU_TPUT_${color_name^^}
        if [[ ! -v $color_var ]]
        then
            bu_log_err "Unknown color[$color_name] in --colors. Expected a BU_TPUT_* color name (e.g. green, yellow, bold)."
            return 1
        fi
        kv+=("$key" "${!color_var}")
    done
    if ((${#kv[@]}))
    then
        BU_RET=$("$BU_OUT_JQ" -cn --args \
            'reduce range(0; $ARGS.positional | length; 2) as $i ({}; .[$ARGS.positional[$i]] = $ARGS.positional[$i + 1])' \
            -- "${kv[@]}")
    fi
}

# ```
# *Description*:
# Get the terminal width for table layout
#
# *Returns*:
# - `$BU_RET`: Terminal width in columns (defaults to 80 if undetectable)
# ```
__bu_out_term_width()
{
    BU_RET=${COLUMNS:-}
    if [[ -z "$BU_RET" ]]
    then
        BU_RET=$(tput cols 2>/dev/null)
    fi
    if [[ -z "$BU_RET" ]] || (( BU_RET < 20 ))
    then
        BU_RET=80
    fi
}

# MARK: Recordifiers (raw -> JSONL)

# ```
# *Description*:
# Construct a single JSON record (one line of JSONL) from key=value pairs.
# Values are properly JSON-escaped via jq --arg.
#
# *Params*:
# - `...`: `key=value` pairs. Use `key:=value` for typed JSON values
#          (numbers, booleans, arrays) via jq --argjson.
#
# *Returns*:
# - stdout: One JSON object on a single line
#
# *Examples*:
# ```bash
# bu_out_record name=bashtab version=0.1.0
# # {"name":"bashtab","version":"0.1.0"}
#
# bu_out_record pid=$$ alive:=true retries:=3
# # {"pid":"12345","alive":true,"retries":3}
# ```
#
# *Notes*:
# - Forks one jq process per call. For loops over many records, prefer
#   emitting TSV and converting once with `bu_out_from_tsv`.
# ```
bu_out_record()
{
    __bu_out_assert_jq || return 1

    local -a jq_args=()
    local prog= sep=
    local pair key value i=0
    for pair in "$@"
    do
        case "$pair" in
        *:=*)
            key=${pair%%:=*}
            value=${pair#*:=}
            __bu_out_validate_key "$key" || return 1
            jq_args+=(--argjson "v$i" "$value")
            ;;
        *=*)
            key=${pair%%=*}
            value=${pair#*=}
            __bu_out_validate_key "$key" || return 1
            jq_args+=(--arg "v$i" "$value")
            ;;
        *)
            bu_log_err "Expected key=value or key:=value, got[$pair]"
            return 1
            ;;
        esac
        prog+="$sep\"$key\":\$v$i"
        sep=,
        ((i++))
    done
    "$BU_OUT_JQ" -cn "${jq_args[@]}" "{$prog}"
}

# ```
# *Description*:
# Convert a TSV stream to JSONL in a single jq process (stream recordifier).
# This is the preferred pattern for loops: printf TSV per record (zero forks),
# then recordify the whole stream at once.
#
# *Params*:
# - `--columns a,b,c`: Comma-separated column names, assigned to TSV fields in order
# - stdin: Tab-separated lines. Fields without a column are dropped;
#          missing trailing fields leave keys absent. Blank lines are skipped.
#
# *Returns*:
# - stdout: JSONL stream
#
# *Examples*:
# ```bash
# printf 'bashtab\t0.1.0\nmyapp\t-\n' | bu_out_from_tsv --columns name,version
# # {"name":"bashtab","version":"0.1.0"}
# # {"name":"myapp","version":"-"}
# ```
#
# *Notes*:
# - Values must not contain tabs or newlines. For arbitrary strings, use
#   `bu_out_record` per record instead.
# ```
bu_out_from_tsv()
{
    __bu_out_assert_jq || return 1

    local columns=
    local shift_by=1
    while (($#))
    do
        case "$1" in
        --columns)
            columns=$2
            shift_by=2
            ;;
        *)
            bu_log_err "Unrecognized option[$1] for bu_out_from_tsv"
            return 1
            ;;
        esac
        if (( $# < shift_by ))
        then
            bu_log_err "Expected $((shift_by - 1)) arguments for option $1"
            return 1
        fi
        shift "$shift_by"
    done
    if [[ -z "$columns" ]]
    then
        bu_log_err "bu_out_from_tsv requires --columns"
        return 1
    fi

    __bu_out_cols_to_json "$columns" || return 1
    local cols_json=$BU_RET

    "$BU_OUT_JQ" -R -c --argjson cols "$cols_json" '
        select(. != "")
        | split("\t")
        | reduce to_entries[] as $e ({};
            if $cols[$e.key] != null then .[$cols[$e.key]] = $e.value else . end)
    '
}

# ```
# *Description*:
# Convert a line-oriented stream to JSONL, one single-key record per line.
# Useful for wrapping line-oriented tools (ls, git, ...) into records.
#
# *Params*:
# - `--column name`: Key to assign each line to (required)
# - stdin: Lines of text
#
# *Returns*:
# - stdout: JSONL stream
#
# *Examples*:
# ```bash
# printf 'a.txt\nb.txt\n' | bu_out_from_lines --column file
# # {"file":"a.txt"}
# # {"file":"b.txt"}
# ```
bu_out_from_lines()
{
    __bu_out_assert_jq || return 1

    local column=
    local shift_by=1
    while (($#))
    do
        case "$1" in
        --column)
            column=$2
            shift_by=2
            ;;
        *)
            bu_log_err "Unrecognized option[$1] for bu_out_from_lines"
            return 1
            ;;
        esac
        if (( $# < shift_by ))
        then
            bu_log_err "Expected $((shift_by - 1)) arguments for option $1"
            return 1
        fi
        shift "$shift_by"
    done
    if [[ -z "$column" ]]
    then
        bu_log_err "bu_out_from_lines requires --column"
        return 1
    fi
    __bu_out_validate_key "$column" || return 1

    "$BU_OUT_JQ" -R -c --arg k "$column" '{($k): .}'
}

# MARK: Transforms (JSONL -> JSONL)

# ```
# *Description*:
# Filter a JSONL stream with a jq boolean expression (PowerShell Where-Object).
# Streams record-by-record with O(1) latency.
#
# *Params*:
# - `$1`: jq expression evaluated per record; records where it is truthy pass.
#         The current record is `.` (e.g. `.version == "-"`, `.name | test("^bu")`).
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: Filtered JSONL stream
#
# *Examples*:
# ```bash
# bu get-command | bu_out_where '.type == "source"'
# ```
#
# *Notes*:
# - The expression is embedded into a jq program verbatim (same trust
#   boundary as writing raw jq).
# ```
bu_out_where()
{
    __bu_out_assert_jq || return 1
    if (($# != 1))
    then
        bu_log_err "bu_out_where expects exactly one jq expression"
        return 1
    fi
    "$BU_OUT_JQ" -c "select($1)"
}

# ```
# *Description*:
# Project a JSONL stream to a subset of fields, reordering and optionally
# renaming them (PowerShell Select-Object).
#
# *Params*:
# - `$1`: Comma-separated field specs. `name` keeps the field as-is;
#         `new=old` renames field `old` to `new`.
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: JSONL stream containing only the selected fields
#
# *Examples*:
# ```bash
# bu get-command | bu_out_select name,type
# bu get-module | bu_out_select name,ver=version
# ```
#
# *Notes*:
# - Field order in the spec determines key order in the output records.
# - Missing fields are emitted as null.
# ```
bu_out_select()
{
    __bu_out_assert_jq || return 1
    if (($# != 1))
    then
        bu_log_err "bu_out_select expects a comma-separated field spec (e.g. 'name,ver=version')"
        return 1
    fi

    local -a specs=()
    local ifs=$IFS
    IFS=','
    # shellcheck disable=SC2206 # Intentional word splitting on commas
    specs=($1)
    IFS=$ifs

    local prog= sep=
    local spec new old
    for spec in "${specs[@]}"
    do
        [[ -z "$spec" ]] && continue
        case "$spec" in
        *=*)
            new=${spec%%=*}
            old=${spec#*=}
            __bu_out_validate_key "$new" || return 1
            __bu_out_validate_key "$old" || return 1
            ;;
        *)
            new=$spec
            old=$spec
            __bu_out_validate_key "$new" || return 1
            ;;
        esac
        prog+="$sep\"$new\":.$old"
        sep=,
    done
    if [[ -z "$prog" ]]
    then
        bu_log_err "bu_out_select got an empty field spec"
        return 1
    fi
    "$BU_OUT_JQ" -c "{$prog}"
}

# ```
# *Description*:
# Sort a JSONL stream by a field (PowerShell Sort-Object). Buffers all input.
# jq ordering rules apply: null < false < true < numbers < strings < arrays < objects.
#
# *Params*:
# - `$1`: Field to sort by
# - `--desc` (optional): Sort descending
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: Sorted JSONL stream
#
# *Examples*:
# ```bash
# bu get-command | bu_out_sort_by noun
# bu get-command | bu_out_sort_by name --desc
# ```
bu_out_sort_by()
{
    __bu_out_assert_jq || return 1

    local key=
    local is_desc=false
    while (($#))
    do
        case "$1" in
        --desc)
            is_desc=true
            ;;
        *)
            if [[ -n "$key" ]]
            then
                bu_log_err "bu_out_sort_by got an unexpected extra argument[$1]"
                return 1
            fi
            key=$1
            ;;
        esac
        shift
    done
    if [[ -z "$key" ]]
    then
        bu_log_err "bu_out_sort_by requires a field to sort by"
        return 1
    fi
    __bu_out_validate_key "$key" || return 1

    if "$is_desc"
    then
        "$BU_OUT_JQ" -sc --arg key "$key" 'sort_by(.[$key]) | reverse | .[]'
    else
        "$BU_OUT_JQ" -sc --arg key "$key" 'sort_by(.[$key]) | .[]'
    fi
}

# MARK: Sinks (JSONL -> display)

# Shared jq prelude for the display formatters.
# - cellstr: null/missing -> "", strings as-is, everything else -> tostring
# - pad($w): right-pad with spaces to width $w
# - ellipsize($w): truncate to width $w with a trailing ellipsis
read -r -d '' __BU_OUT_JQ_PRELUDE <<'EOF' || :
def cellstr: if . == null then "" elif type == "string" then . else tostring end;
def pad($w): . + " " * ($w - length);
def ellipsize($w): if length > $w then .[0:($w - ($ellipsis | length))] + $ellipsis else . end;
def rtrim: sub(" +$"; "");
EOF

# ```
# *Description*:
# Render a JSONL stream as an aligned table (PowerShell Format-Table).
#
# *Params*:
# - `--columns a,b,c`: Columns to display, in order. Each entry may carry a
#                      display label as `key:Label` (e.g. `name:Module`).
#                      Default: keys of the first record (insertion order).
#                      Required with --stream.
# - `--stream`:        Stream rows as they arrive using proportional column
#                      widths derived from the terminal width, instead of
#                      buffering all records for optimal auto-widths.
# - `--colors k=color,...`: Colorize column cells (see __bu_out_colors_to_json)
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: Header row, separator row, then one aligned row per record.
#           Empty input produces no output (PowerShell semantics).
#
# *Notes*:
# - Default mode buffers all input (jq slurp) to compute optimal column
#   widths, then shrinks the widest columns until the table fits the
#   terminal width (ellipsis truncation). This mirrors Format-Table -AutoSize.
# - The header is bold when stdout is a terminal.
# ```
bu_format_table()
{
    __bu_out_assert_jq || return 1

    local columns=
    local colors=
    local is_stream=false
    local shift_by=1
    while (($#))
    do
        case "$1" in
        --columns)
            columns=$2
            shift_by=2
            ;;
        --colors)
            colors=$2
            shift_by=2
            ;;
        --stream)
            is_stream=true
            ;;
        *)
            bu_log_err "Unrecognized option[$1] for bu_format_table"
            return 1
            ;;
        esac
        if (( $# < shift_by ))
        then
            bu_log_err "Expected $((shift_by - 1)) arguments for option $1"
            return 1
        fi
        shift "$shift_by"
    done

    __bu_out_colspecs_to_json "$columns" || return 1
    local cols_json=$BU_RET
    __bu_out_colors_to_json "$colors" || return 1
    local colors_json=$BU_RET
    __bu_out_term_width
    local termw=$BU_RET

    # Bold header on terminals only
    local bold= reset=
    if [[ -t 1 ]]
    then
        bold=$BU_TPUT_BOLD
        reset=$BU_TPUT_RESET
    fi

    if "$is_stream"
    then
        if [[ "$cols_json" == '[]' ]]
        then
            bu_log_err "bu_format_table --stream requires --columns (cannot inspect the first record without buffering)"
            return 1
        fi
        "$BU_OUT_JQ" -rn \
            --argjson cols "$cols_json" \
            --argjson colors "$colors_json" \
            --argjson termw "$termw" \
            --argjson minw 4 \
            --arg bold "$bold" --arg reset "$reset" --arg ellipsis "…" \
            "$__BU_OUT_JQ_PRELUDE"'
            ($cols | length) as $n
            | ([$cols[] | {key: .key, header: .header, width: ([$minw, ((($termw - 2 * ($n - 1)) / $n) | floor)] | max)}]) as $spec
            | def rowline($r): $spec | map(
                  . as $s
                  | ($r[$s.key] | cellstr | ellipsize($s.width) | pad($s.width)) as $cell
                  | ($colors[$s.key] // "") + $cell + (if $colors[$s.key] then $reset else "" end)
              ) | join("  ");
            ($spec | map(. as $s | $bold + ($s.header | pad($s.width)) + $reset) | join("  ") | rtrim),
            ($spec | map("-" * .width) | join("  ") | rtrim),
            (inputs | rowline(.) | rtrim)
            '
        return
    fi

    "$BU_OUT_JQ" -s -r \
        --argjson cols "$cols_json" \
        --argjson colors "$colors_json" \
        --argjson termw "$termw" \
        --argjson minw 4 \
        --arg bold "$bold" --arg reset "$reset" --arg ellipsis "…" \
        "$__BU_OUT_JQ_PRELUDE"'
        . as $rows
        | if ($rows | length) == 0 then empty
        else
        ($cols | if length == 0 then $rows[0] | keys_unsorted | map({key: ., header: .}) else . end) as $cols
        | ($cols | map(. as $c | {key: $c.key, header: $c.header, width: ([($c.header | length)] + [$rows[] | .[$c.key] | cellstr | length] | max)})) as $init
        | def fit($spec):
              if (($spec | map(.width) | add) + 2 * ($spec | length - 1)) <= $termw then $spec
              elif ($spec | all(.[]; .width <= $minw)) then $spec
              else
                  ($spec | max_by(.width) | .key) as $mk
                  | fit($spec | map(if .key == $mk then .width -= 1 else . end))
              end;
        fit($init) as $spec
        | ($spec | map(. as $s | $bold + ($s.header | pad($s.width)) + $reset) | join("  ") | rtrim),
          ($spec | map("-" * .width) | join("  ") | rtrim),
          ($rows[] | . as $r | $spec | map(
              . as $s
              | ($r[$s.key] | cellstr | ellipsize($s.width) | pad($s.width)) as $cell
              | ($colors[$s.key] // "") + $cell + (if $colors[$s.key] then $reset else "" end)
          ) | join("  ") | rtrim)
        end
        '
}

# ```
# *Description*:
# Render a JSONL stream as a list of key-value blocks (PowerShell Format-List).
# Streams record-by-record with O(1) latency.
#
# *Params*:
# - `--columns a,b,c`: Fields to display, in order. Each entry may carry a
#                      display label as `key:Label` (e.g. `name:Module`).
#                      Default: keys of each record.
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: `key : value` lines per record, separated by blank lines
#
# *Examples*:
# ```bash
# echo '{"name":"bashtab","version":"0.1.0"}' | bu_format_list
# # name    : bashtab
# # version : 0.1.0
# ```
bu_format_list()
{
    __bu_out_assert_jq || return 1

    local columns=
    local shift_by=1
    while (($#))
    do
        case "$1" in
        --columns)
            columns=$2
            shift_by=2
            ;;
        *)
            bu_log_err "Unrecognized option[$1] for bu_format_list"
            return 1
            ;;
        esac
        if (( $# < shift_by ))
        then
            bu_log_err "Expected $((shift_by - 1)) arguments for option $1"
            return 1
        fi
        shift "$shift_by"
    done

    __bu_out_colspecs_to_json "$columns" || return 1
    local cols_json=$BU_RET

    "$BU_OUT_JQ" -r \
        --argjson cols "$cols_json" \
        "$__BU_OUT_JQ_PRELUDE"'
        . as $r
        | ($cols | if length == 0 then $r | keys_unsorted | map({key: ., header: .}) else . end) as $cs
        | ($cs | map(.header | length) | max) as $lw
        | ($cs | map(. as $c | ($c.header | pad($lw)) + " : " + ($r[$c.key] | cellstr)) | join("\n")),
          ""
        '
}

# ```
# *Description*:
# Render a JSONL stream as a pretty-printed JSON array (ConvertTo-Json).
# Buffers all input.
#
# *Params*:
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: JSON array
# ```
bu_format_json()
{
    __bu_out_assert_jq || return 1
    "$BU_OUT_JQ" -s .
}

# ```
# *Description*:
# Normalize a JSONL stream (compact, one validated object per line).
# Pure passthrough with O(1) latency.
#
# *Params*:
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: JSONL stream
# ```
bu_format_jsonl()
{
    __bu_out_assert_jq || return 1
    "$BU_OUT_JQ" -c .
}

# ```
# *Description*:
# Render a JSONL stream as TSV for scripting. Streams record-by-record.
# Embedded tabs/newlines in values are escaped by jq @tsv.
#
# *Params*:
# - `--columns a,b,c`: Fields to emit, in order. Default: keys of each record.
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: Tab-separated lines (no header row)
# ```
bu_format_tsv()
{
    __bu_out_assert_jq || return 1

    local columns=
    local shift_by=1
    while (($#))
    do
        case "$1" in
        --columns)
            columns=$2
            shift_by=2
            ;;
        *)
            bu_log_err "Unrecognized option[$1] for bu_format_tsv"
            return 1
            ;;
        esac
        if (( $# < shift_by ))
        then
            bu_log_err "Expected $((shift_by - 1)) arguments for option $1"
            return 1
        fi
        shift "$shift_by"
    done

    __bu_out_cols_to_json "$columns" || return 1
    local cols_json=$BU_RET

    "$BU_OUT_JQ" -r \
        --argjson cols "$cols_json" \
        "$__BU_OUT_JQ_PRELUDE"'
        . as $r
        | ($cols | if length == 0 then $r | keys_unsorted else . end) as $cs
        | [$cs[] as $c | $r[$c] | cellstr] | @tsv
        '
}

# MARK: Pipeline field completion

# ```
# *Description*:
# Register the record fields that a producer command emits, enabling
# pipeline-aware field completion after a pipe (e.g. in bu select-object).
#
# *Params*:
# - `$1`: Producer command-line prefix (e.g. `bu get-pokemon`, `kubectl get pods`)
# - `...`: Field names in record order
#
# *Examples*:
# ```bash
# bu_register_output_fields "bu get-pokemon" name id type hp attack
# ```
# ```
bu_register_output_fields()
{
    local -r producer=$1
    shift
    if [[ -z "$producer" || $# == 0 ]]
    then
        bu_log_err "Usage: bu_register_output_fields <producer-prefix> <field...>"
        return 1
    fi
    local field
    for field
    do
        __bu_out_validate_key "$field" || return 1
    done
    BU_OUT_PRODUCER_FIELDS[$producer]="$*"
}

# ```
# *Description*:
# Autocomplete helper (used via the `--ret` DSL): suggest record fields based
# on the pipeline preceding the cursor (PowerShell-style pipeline awareness).
#
# Field sources, in order:
# 1. Static registry `BU_OUT_PRODUCER_FIELDS` (longest prefix match on the
#    producer pipeline, so flags and later stages don't break the match)
# 2. Opt-in probing: when `BU_OUT_PROBE_PIPELINE=true` and the producer head
#    is in `BU_OUT_PROBE_COMMANDS`, the producer is executed as typed and the
#    keys of its first JSONL record are used
#
# *Params*:
# - `--dot` (optional): Prefix suggestions with `.` for jq-style expressions
#           (e.g. `.name`), used by bu where-object
# - `$1`: Current word being completed (appended by the --ret DSL)
#
# *Returns*:
# - `$BU_RET`: Candidate completions. Comma-aware: completing `name,ve`
#              yields `name,version`, ... excluding already-used fields.
#
# *Notes*:
# - Producer resolution order: `command_line_front_before_pipe` (fzf binding),
#   then `pipe_before` (tree-sitter binding), then a `COMP_WORDS` walk.
#   All are read via dynamic scope from the completion machinery.
# - The COMP_WORDS fallback requires the pipe as a standalone word (`a | b`).
# ```
__bu_out_complete_pipeline_fields()
{
    local is_dot=false
    if [[ "$1" == --dot ]]
    then
        is_dot=true
        shift
    fi
    local -r cur_word=${1:-}
    BU_RET=()

    # Resolve the producer pipeline text, most accurate source first:
    # - command_line_front_before_pipe: set by the fzf binding (legacy parser)
    # - pipe_before: set by the tree-sitter binding (BU_TS_RESULT[pipeBefore])
    # Both are locals of the completion bindings, visible via dynamic scope.
    local producer_str=${command_line_front_before_pipe:-${pipe_before:-}}
    local producer_eval=
    if [[ -n "$producer_str" ]]
    then
        # Strip trailing whitespace, the pipe character, then whitespace again
        producer_str=${producer_str%"${producer_str##*[![:space:]]}"}
        producer_str=${producer_str%|}
        producer_str=${producer_str%"${producer_str##*[![:space:]]}"}
        producer_eval=$producer_str
    else
        # Fallback: walk COMP_WORDS (dynamically scoped from the completion
        # driver) for the pipe that starts the current command segment
        [[ -z "$COMP_CWORD" ]] && return 1
        local i pipe_idx=
        for (( i = COMP_CWORD - 1; i >= 0; i-- ))
        do
            if [[ "${COMP_WORDS[i]}" == '|' ]]
            then
                pipe_idx=$i
                break
            fi
        done
        # Not in a pipeline: no producer to infer fields from
        [[ -z "$pipe_idx" ]] && return 1

        # The producer segment starts after the previous control operator
        local seg_start=0
        for (( i = pipe_idx - 1; i >= 0; i-- ))
        do
            case "${COMP_WORDS[i]}" in
            '|'|';'|'&&'|'||'|'('|')')
                seg_start=$((i + 1))
                break
                ;;
            esac
        done
        local -a producer_words=("${COMP_WORDS[@]:seg_start:pipe_idx-seg_start}")
        ((${#producer_words[@]} == 0)) && return 1
        producer_str="${producer_words[*]}"
        printf -v producer_eval '%q ' "${producer_words[@]}"
    fi
    [[ -z "$producer_str" ]] && return 1
    local -r producer_head=${producer_str%%[[:space:]]*}

    local -a fields=()

    # 1. Static registry, longest matching producer prefix wins
    local key best_key=
    for key in "${!BU_OUT_PRODUCER_FIELDS[@]}"
    do
        if [[ "$producer_str" == "$key" || "$producer_str" == "$key "* ]] && (( ${#key} > ${#best_key} ))
        then
            best_key=$key
        fi
    done
    if [[ -n "$best_key" ]]
    then
        # shellcheck disable=SC2206 # Intentional word splitting of the field list
        fields=(${BU_OUT_PRODUCER_FIELDS[$best_key]})
    elif "$BU_OUT_PROBE_PIPELINE" && [[ -n "${BU_OUT_PROBE_COMMANDS[$producer_head]:-}" && -n "$BU_OUT_JQ" ]]
    then
        # 2. Opt-in probing: execute the producer as typed, read the keys of
        # the first record. Auto-dispatch makes piped bu commands emit JSONL.
        local first_line
        first_line=$(eval "$producer_eval" 2>/dev/null | head -1)
        if [[ -n "$first_line" ]]
        then
            local keys
            keys=$("$BU_OUT_JQ" -r 'if type == "object" then keys_unsorted[] else empty end' <<<"$first_line" 2>/dev/null)
            [[ -n "$keys" ]] && mapfile -t fields <<<"$keys"
        fi
    fi
    ((${#fields[@]} == 0)) && return 1

    # Comma-aware emission: completing "name,ve" suggests "name,version" etc.,
    # excluding fields already present before the last comma
    local prefix=
    local -A used=()
    if [[ "$cur_word" == *,* ]]
    then
        prefix=${cur_word%,*},
        local used_field
        local ifs=$IFS
        IFS=','
        for used_field in ${cur_word%,*}
        do
            used[$used_field]=1
        done
        IFS=$ifs
    fi

    local field candidate
    for field in "${fields[@]}"
    do
        [[ -n "${used[$field]:-}" ]] && continue
        candidate=$field
        "$is_dot" && candidate=.$field
        BU_RET+=("${prefix}${candidate}")
    done
}

# MARK: Dispatcher (Out-Default)

# ```
# *Description*:
# Format a JSONL stream, auto-detecting the best format (PowerShell Out-Default).
#
# Format resolution order (first match wins):
# 1. Explicit `--format`
# 2. `$BU_OUTPUT_FORMAT` environment variable
# 3. stdout is a terminal -> `table`; otherwise (pipe/file) -> `jsonl`
#
# *Params*:
# - `--format auto|table|list|json|jsonl|tsv`: Output format (default: auto)
# - `--columns a,b,c`: Forwarded to table/list/tsv formatters
# - `--stream`: Forwarded to the table formatter
# - `--colors k=color,...`: Forwarded to the table formatter
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: Formatted output
#
# *Examples*:
# ```bash
# bu get-module --format jsonl | bu out --format table --columns name,version
# ```
bu_out()
{
    __bu_out_assert_jq || return 1

    local format=auto
    local columns=
    local colors=
    local is_stream=false
    local shift_by=1
    while (($#))
    do
        case "$1" in
        --format)
            format=$2
            shift_by=2
            ;;
        --columns)
            columns=$2
            shift_by=2
            ;;
        --colors)
            colors=$2
            shift_by=2
            ;;
        --stream)
            is_stream=true
            ;;
        *)
            bu_log_err "Unrecognized option[$1] for bu_out"
            return 1
            ;;
        esac
        if (( $# < shift_by ))
        then
            bu_log_err "Expected $((shift_by - 1)) arguments for option $1"
            return 1
        fi
        shift "$shift_by"
    done

    if [[ "$format" == auto || -z "$format" ]]
    then
        if [[ -n "$BU_OUTPUT_FORMAT" ]]
        then
            format=$BU_OUTPUT_FORMAT
        elif [[ -t 1 ]]
        then
            format=table
        else
            format=jsonl
        fi
    fi

    local -a formatter_args=()
    case "$format" in
    table)
        [[ -n "$columns" ]] && formatter_args+=(--columns "$columns")
        [[ -n "$colors" ]] && formatter_args+=(--colors "$colors")
        "$is_stream" && formatter_args+=(--stream)
        bu_format_table "${formatter_args[@]}"
        ;;
    list)
        [[ -n "$columns" ]] && formatter_args+=(--columns "$columns")
        bu_format_list "${formatter_args[@]}"
        ;;
    tsv)
        [[ -n "$columns" ]] && formatter_args+=(--columns "$columns")
        bu_format_tsv "${formatter_args[@]}"
        ;;
    json)
        bu_format_json
        ;;
    jsonl)
        bu_format_jsonl
        ;;
    *)
        bu_log_err "Unrecognized format[$format]. Expected one of: auto, table, list, json, jsonl, tsv"
        return 1
        ;;
    esac
}
