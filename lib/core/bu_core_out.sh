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
# Convert a comma-separated column list to a JSON array
#
# *Params*:
# - `$1`: Comma-separated columns (e.g. `name,version,path`). Empty string yields `[]`.
#
# *Returns*:
# - `$BU_RET`: JSON array (e.g. `["name","version","path"]`)
# ```
__bu_out_cols_to_json()
{
    local -a cols=()
    local col
    local ifs=$IFS
    IFS=','
    # shellcheck disable=SC2206 # Intentional word splitting on commas
    cols=($1)
    IFS=$ifs
    local -a valid=()
    for col in "${cols[@]}"
    do
        [[ -z "$col" ]] && continue
        __bu_out_validate_key "$col" || return 1
        valid+=("$col")
    done
    if ((${#valid[@]} == 0))
    then
        BU_RET='[]'
    else
        BU_RET=$("$BU_OUT_JQ" -cn --args '$ARGS.positional' -- "${valid[@]}")
    fi
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
# - `--columns a,b,c`: Columns to display, in order. Default: keys of the
#                      first record (insertion order). Required with --stream.
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

    __bu_out_cols_to_json "$columns" || return 1
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
            | ([$cols[] | {key: ., width: ([$minw, ((($termw - 2 * ($n - 1)) / $n) | floor)] | max)}]) as $spec
            | def rowline($r): $spec | map(
                  . as $s
                  | ($r[$s.key] | cellstr | ellipsize($s.width) | pad($s.width)) as $cell
                  | ($colors[$s.key] // "") + $cell + (if $colors[$s.key] then $reset else "" end)
              ) | join("  ");
            ($spec | map(. as $s | $bold + ($s.key | pad($s.width)) + $reset) | join("  ") | rtrim),
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
        ($cols | if length == 0 then $rows[0] | keys_unsorted else . end) as $cols
        | ($cols | map(. as $c | {key: $c, width: ([($c | length)] + [$rows[] | .[$c] | cellstr | length] | max)})) as $init
        | def fit($spec):
              if (($spec | map(.width) | add) + 2 * ($spec | length - 1)) <= $termw then $spec
              elif ($spec | all(.[]; .width <= $minw)) then $spec
              else
                  ($spec | max_by(.width) | .key) as $mk
                  | fit($spec | map(if .key == $mk then .width -= 1 else . end))
              end;
        fit($init) as $spec
        | ($spec | map(. as $s | $bold + ($s.key | pad($s.width)) + $reset) | join("  ") | rtrim),
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
# - `--columns a,b,c`: Fields to display, in order. Default: keys of each record.
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

    __bu_out_cols_to_json "$columns" || return 1
    local cols_json=$BU_RET

    "$BU_OUT_JQ" -r \
        --argjson cols "$cols_json" \
        "$__BU_OUT_JQ_PRELUDE"'
        . as $r
        | ($cols | if length == 0 then $r | keys_unsorted else . end) as $cs
        | ($cs | map(length) | max) as $lw
        | ($cs | map(. as $c | ($c | pad($lw)) + " : " + ($r[$c] | cellstr)) | join("\n")),
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
