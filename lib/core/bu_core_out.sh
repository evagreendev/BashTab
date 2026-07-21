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

# Standard output formats for structured commands.
# Used by --format flags and Out-Default auto-detection.
BU_OUT_FORMATS=(auto table list json jsonl tsv)

# Static field registry: producer command-line prefix -> space-separated
# record fields. Consulted first by __bu_out_complete_pipeline_fields when
# completing after a pipe. Longest prefix match wins, so fields stay correct
# even when the producer carries flags or later pipeline stages.
# Extend via bu_register_output_fields (e.g. from a module preinit script).
declare -A -g BU_OUT_PRODUCER_FIELDS=(
    ["bu get-command"]="name verb noun namespace type"
    ["bu get-module"]="name version path"
    # jc parser fields (registered by parser name for convert-from-jc)
    ["bu convert-from-jc --parser ls"]="filename flags links owner group size date"
    ["bu convert-from-jc --parser ps"]="user pid vsz rss tty stat start time command cpu_percent mem_percent"
    ["bu convert-from-jc --parser df"]="filesystem 1k_blocks used available mounted_on use_percent"
    ["bu convert-from-jc --parser dig"]="id opcode status flags query_num answer_num authority_num additional_num opt_pseudosection question answer query_time server when rcvd when_epoch when_epoch_utc"
    ["bu convert-from-jc --parser free"]="type total used free shared buff_cache available"
    ["bu convert-from-jc --parser mount"]="filesystem mount_point type options"
    ["bu convert-from-jc --parser uptime"]="time uptime users load_1m load_5m load_15m time_hour time_minute time_second uptime_days uptime_hours uptime_minutes uptime_total_seconds"
    ["bu convert-from-jc --parser uname"]="kernel_name node_name kernel_release operating_system processor hardware_platform machine kernel_version"
    ["bu convert-from-jc --parser env"]="name value"
    ["bu convert-from-jc --parser id"]="uid gid groups"
    ["bu convert-from-jc --parser du"]="size name"
    ["bu convert-from-jc --parser stat"]="file size blocks io_blocks type device inode links access flags uid user gid group access_time modify_time change_time birth_time access_time_epoch access_time_epoch_utc modify_time_epoch modify_time_epoch_utc change_time_epoch change_time_epoch_utc birth_time_epoch birth_time_epoch_utc"
    ["bu convert-from-jc --parser ifconfig"]="name flags state mtu type mac_addr ipv4_addr ipv4_mask ipv4_bcast ipv6_addr ipv6_mask ipv6_scope ipv6_type metric rx_packets rx_errors rx_dropped rx_overruns rx_frame tx_packets tx_errors tx_dropped tx_overruns tx_carrier tx_collisions rx_bytes tx_bytes ipv4"
    ["bu convert-from-jc --parser netstat"]="proto recv_q send_q local_address foreign_address state program_name kind local_port foreign_port transport_protocol network_protocol local_port_num"
    ["bu convert-from-jc --parser arp"]="name address hwtype hwaddress iface"
    ["bu convert-from-jc --parser dpkg-l"]="codes name version architecture description desired status"
    ["bu convert-from-jc --parser iostat"]="percent_user percent_nice percent_system percent_iowait percent_steal percent_idle type"
    ["bu convert-from-jc --parser vmstat"]="runnable_procs uninterruptible_sleeping_procs virtual_mem_used free_mem buffer_mem cache_mem inactive_mem active_mem swap_in swap_out blocks_in blocks_out interrupts context_switches user_time system_time idle_time io_wait_time stolen_time timestamp timezone"
    ["bu convert-from-jc --parser lsof"]="command pid user fd type device size_off node name"
    ["bu convert-from-jc --parser wc"]="filename lines words characters"
    # npm wrappers
    ["bu get-npm-package"]="name version resolved depth _path _parent_path"
    ["bu get-npm-outdated"]="name current wanted latest dependent location"
    ["bu get-pnpm-package"]="name version resolved from description license path depth _path _parent_path"
    ["bu get-pgrep-process"]="pid command"
    ["bu get-npm-audit"]="name severity is_direct title url range fix_version fix_is_breaking via"
    ["bu get-pnpm-outdated"]="name current wanted latest is_deprecated dependency_type"
    ["bu get-docker-container"]="ID Image Command CreatedAt RunningFor Ports Status Size Names Labels Mounts Networks"
    ["bu get-docker-image"]="ID Repository Tag CreatedAt CreatedSince Size"
    ["bu get-docker-volume"]="Driver Labels Links Mountpoint Name Scope Size"
    ["bu get-docker-network"]="ID Name Driver Scope"
    # Dedicated jc-wrapper cmdlets (field aliases for convert-from-jc parsers)
    ["bu get-file"]="filename flags links owner group size date"
    ["bu get-process"]="user pid vsz rss tty stat start time command cpu_percent mem_percent"
    ["bu get-disk"]="filesystem 1k_blocks used available mounted_on use_percent"
    ["bu get-dns"]="id opcode status flags query_num answer_num authority_num additional_num opt_pseudosection question answer query_time server when rcvd when_epoch when_epoch_utc"
    ["bu get-memory"]="type total used free shared buff_cache available"
    ["bu get-mount"]="filesystem mount_point type options"
    ["bu get-uptime"]="time uptime users load_1m load_5m load_15m time_hour time_minute time_second uptime_days uptime_hours uptime_minutes uptime_total_seconds"
    ["bu get-system"]="kernel_name node_name kernel_release operating_system processor hardware_platform machine kernel_version"
    ["bu get-environment"]="name value"
    ["bu get-identity"]="uid gid groups"
    ["bu get-file-usage"]="size name"
    ["bu get-file-stat"]="file size blocks io_blocks type device inode links access flags uid user gid group access_time modify_time change_time birth_time access_time_epoch access_time_epoch_utc modify_time_epoch modify_time_epoch_utc change_time_epoch change_time_epoch_utc birth_time_epoch birth_time_epoch_utc"
    ["bu get-interface"]="name flags state mtu type mac_addr ipv4_addr ipv4_mask ipv4_bcast ipv6_addr ipv6_mask ipv6_scope ipv6_type metric rx_packets rx_errors rx_dropped rx_overruns rx_frame tx_packets tx_errors tx_dropped tx_overruns tx_carrier tx_collisions rx_bytes tx_bytes ipv4"
    ["bu get-network"]="proto recv_q send_q local_address foreign_address state program_name kind local_port foreign_port transport_protocol network_protocol local_port_num"
    ["bu get-socket"]="proto recv_q send_q local_address foreign_address state program_name kind local_port foreign_port transport_protocol network_protocol local_port_num"
    ["bu get-arp-entry"]="name address hwtype hwaddress iface"
    ["bu get-cpu-stat"]="percent_user percent_nice percent_system percent_iowait percent_steal percent_idle type"
    ["bu get-memory-stat"]="runnable_procs uninterruptible_sleeping_procs virtual_mem_used free_mem buffer_mem cache_mem inactive_mem active_mem swap_in swap_out blocks_in blocks_out interrupts context_switches user_time system_time idle_time io_wait_time stolen_time timestamp timezone"
    ["bu get-open-file"]="command pid user fd type device size_off node name"
    ["bu get-count"]="filename lines words characters"
    ["bu get-dpkg-package"]="codes name version architecture description desired status"
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

# Predefined palette for --colors auto (rotating rainbow).
# Keys: BU_TPUT_* color names (lowercase), in rotation order.
__BU_OUT_RAINBOW=(
    blue
    green
    yellow
    red
    violet
    vscode_orange
    vscode_pink
    dark_blue
)

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
# - `--unique` (optional): Deduplicate records after projection (first
#         occurrence wins, order preserved). Equivalent to piping through
#         `bu_out_distinct` after the select.
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: JSONL stream containing only the selected fields
#
# *Examples*:
# ```bash
# bu get-command | bu_out_select name,type
# bu get-module | bu_out_select name,ver=version
# bu get-command | bu_out_select verb --unique
# ```
#
# *Notes*:
# - Field order in the spec determines key order in the output records.
# - Missing fields are emitted as null.
# ```
bu_out_select()
{
    __bu_out_assert_jq || return 1

    local is_unique=false
    local field_spec=
    while (($#))
    do
        case "$1" in
        --unique)
            is_unique=true
            ;;
        *)
            if [[ -n "$field_spec" ]]
            then
                bu_log_err "bu_out_select got an unexpected extra argument[$1]"
                return 1
            fi
            field_spec=$1
            ;;
        esac
        shift
    done
    if [[ -z "$field_spec" ]]
    then
        bu_log_err "bu_out_select expects a comma-separated field spec (e.g. 'name,ver=version')"
        return 1
    fi

    local -a specs=()
    local ifs=$IFS
    IFS=','
    # shellcheck disable=SC2206 # Intentional word splitting on commas
    specs=($field_spec)
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

    if "$is_unique"
    then
        "$BU_OUT_JQ" -c "{$prog}" | bu_out_distinct
    else
        "$BU_OUT_JQ" -c "{$prog}"
    fi
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

# ```
# *Description*:
# Remove duplicate records from a JSONL stream (SELECT DISTINCT /
# Select-Object -Unique). The first occurrence wins; original order is
# preserved (unlike group-by, which sorts by key). Records are compared
# with key-order canonicalization, so {"a":1,"b":2} equals {"b":2,"a":1}.
# Streams emission (first occurrences appear with O(1) latency); memory
# grows with the number of distinct records seen, which is inherent to dedupe.
#
# *Params*:
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: JSONL stream without duplicate records
#
# *Examples*:
# ```bash
# bu get-command | bu_out_select verb | bu_out_distinct
# ```
bu_out_distinct()
{
    __bu_out_assert_jq || return 1
    "$BU_OUT_JQ" -cn '
        def canon: if type == "object" then to_entries | sort_by(.key) | map({key: .key, value: (.value | canon)}) | from_entries
                   elif type == "array" then map(canon) else . end;
        foreach inputs as $r ({seen: {}};
            ($r | canon | tostring) as $k
            | if .seen[$k] then . + {emit: false} else (.seen[$k] = 1) + {emit: true} end;
            select(.emit) | $r)
    '
}

# MARK: Sinks (JSONL -> display)

# Shared jq prelude for the display formatters.
# - cellstr: null/missing -> "", strings as-is, everything else -> tostring
# - pad($w): right-pad with spaces to width $w
# - ellipsize($w): truncate to width $w with a trailing ellipsis
read -r -d '' __BU_OUT_JQ_PRELUDE <<'EOF' || :
def cellstr: if . == null then "" elif type == "string" then . else tostring end;
def ansistrip: gsub("\u001b[^a-zA-Z]*[a-zA-Z]"; "");
def ansilen: ansistrip | length;
def pad($w): . + " " * ($w - ansilen);
def ellipsize($w): if ansilen > $w then .[0:($w - ($ellipsis | length))] + $ellipsis else . end;
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
    local rainbow_json='[]'
    if [[ "$colors" == auto ]]
    then
        # Build a JSON array of ANSI escape codes from the palette names
        local -a _ansi_palette=()
        local _cname _cvar
        for _cname in "${__BU_OUT_RAINBOW[@]}"
        do
            _cvar=BU_TPUT_${_cname^^}
            _ansi_palette+=("${!_cvar}")
        done
        rainbow_json=$("$BU_OUT_JQ" -cn --args '$ARGS.positional' -- "${_ansi_palette[@]}")
        __bu_out_colors_to_json ""  # validate, produce empty
        colors_json='{}'
    else
        __bu_out_colors_to_json "$colors" || return 1
        colors_json=$BU_RET
    fi
    __bu_out_term_width
    local termw=$BU_RET

    # Bold header on terminals only; reset always needed when colours are active
    local bold= reset=$BU_TPUT_RESET
    if [[ -t 1 ]]
    then
        bold=$BU_TPUT_BOLD
    fi
    # No explicit or auto colours → suppress reset so plain output stays clean
    if [[ -z "$colors" && "$rainbow_json" == '[]' ]]
    then
        reset=
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
            --argjson rainbow "$rainbow_json" \
            --argjson termw "$termw" \
            --argjson minw 4 \
            --arg bold "$bold" --arg reset "$reset" --arg ellipsis "…" \
            "$__BU_OUT_JQ_PRELUDE"'
            (if ($rainbow | length) > 0 then
               reduce range(0; $cols | length) as $i ({};
                   .[$cols[$i].key] = $rainbow[$i % ($rainbow | length)])
             else $colors end) as $colors
            | ($cols | length) as $n
            | ([$cols[] | {key: .key, header: .header, width: ([$minw, ((($termw - 2 * ($n - 1)) / $n) | floor)] | max)}]) as $spec
            | def rowline($r): $spec | map(
                  . as $s
                  | ($r[$s.key] | cellstr | ellipsize($s.width) | pad($s.width)) as $cell
                  | ($colors[$s.key] // "") + $cell + (if $colors[$s.key] then $reset else "" end)
              ) | join("  ");
            ($spec | map(. as $s | $bold + ($s.header | ellipsize($s.width) | pad($s.width)) + $reset) | join("  ") | rtrim),
            ($spec | map("-" * .width) | join("  ") | rtrim),
            (inputs | rowline(.) | rtrim)
            '
        return
    fi

    "$BU_OUT_JQ" -s -r \
        --argjson cols "$cols_json" \
        --argjson colors "$colors_json" \
        --argjson rainbow "$rainbow_json" \
        --argjson termw "$termw" \
        --arg bold "$bold" --arg reset "$reset" --arg ellipsis "…" \
        "$__BU_OUT_JQ_PRELUDE"'
        . as $rows
        | if ($rows | length) == 0 then empty
        else
        ($cols | if length == 0 then $rows[0] | keys_unsorted | map({key: ., header: .}) else . end) as $cols
        | (if ($rainbow | length) > 0 then
             reduce range(0; $cols | length) as $i ({};
                 .[$cols[$i].key] = $rainbow[$i % ($rainbow | length)])
           else $colors end) as $colors
        | ([4, (if ($cols | length) > 10 then 6 elif ($cols | length) > 6 then 5 else 4 end)] | max) as $minw
        | ($cols | map(. as $c | {key: $c.key, header: $c.header, width: ([($c.header | length)] + [$rows[] | .[$c.key] | cellstr | ansilen] | max)})) as $init
        | def fit($spec):
              if ($spec | length) <= 1 then $spec
              elif (($spec | map(.width) | add) + 2 * ($spec | length - 1)) <= $termw then $spec
              elif ($spec | all(.[]; .width <= $minw)) then
                  # Even at min widths the table overflows — drop rightmost columns
                  fit($spec[:-1])
              else
                  # Shrink the widest column that is above the minimum
                  ($spec | map(select(.width > $minw)) | max_by(.width) | .key) as $mk
                  | fit($spec | map(if .key == $mk then .width -= 1 else . end))
              end;
        fit($init) as $spec
        | (if ($spec | length) < ($cols | length) then
              debug("showing \($spec | length) of \($cols | length) columns (use --columns or --format list)")
           else . end)
        | ($spec | map(. as $s | $bold + ($s.header | ellipsize($s.width) | pad($s.width)) + $reset) | join("  ") | rtrim),
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

# ```
# *Description*:
# Group a JSONL stream by one or more key fields, emitting one flat record
# per group (SQL GROUP BY with aggregates). Buffers all input (jq slurp).
#
# *Params*:
# - `--keys a[,b]`: Group key fields (comma-separated; composite key)
# - `--agg spec`:   Aggregate spec, repeatable AND comma-separated:
#                   `[name=]func[:field]`
#                   - `count`          group size
#                   - `sum:f`/`avg:f`  numeric only (non-numbers ignored)
#                   - `min:f`/`max:f`  non-null values, jq total ordering
#                   - `first:f`/`last:f`  by pipeline order
#                   - `collect:f`      array of the field's values
#                   Default output name: `count`, or `func_field` (e.g. `avg_hp`)
# - stdin: JSONL stream
#
# *Returns*:
# - stdout: One JSON record per group: key fields + aggregate fields.
#           Records missing a key field form a null-key group.
#           Empty input produces no output.
#
# *Examples*:
# ```bash
# bu get-command --format jsonl | bu_out_group_by --keys verb --agg count
# bu get-pokemon --format jsonl | bu_out_group_by --keys type --agg count,avg:hp,total=sum:hp
# # No --agg: emits distinct key combinations (SQL SELECT DISTINCT)
# ```
bu_out_group_by()
{
    __bu_out_assert_jq || return 1

    local keys=
    local -a agg_specs=()
    local shift_by=1
    while (($#))
    do
        case "$1" in
        --keys)
            keys=$2
            shift_by=2
            ;;
        --agg)
            local spec ifs=$IFS
            IFS=','
            # shellcheck disable=SC2206 # Intentional word splitting on commas
            for spec in $2; do [[ -n "$spec" ]] && agg_specs+=("$spec"); done
            IFS=$ifs
            shift_by=2
            ;;
        *)
            bu_log_err "Unrecognized option[$1] for bu_out_group_by"
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
    if [[ -z "$keys" ]]
    then
        bu_log_err "bu_out_group_by requires --keys"
        return 1
    fi
    __bu_out_cols_to_json "$keys" || return 1
    local keys_json=$BU_RET

    # Generate one jq fragment per aggregate spec
    local fragments= sep=
    local name body func field fragment
    for spec in "${agg_specs[@]}"
    do
        case "$spec" in
        *=*) name=${spec%%=*}; body=${spec#*=} ;;
        *)   name=; body=$spec ;;
        esac
        func=${body%%:*}
        field=${body#*:}
        [[ "$field" == "$body" ]] && field=
        [[ -z "$name" ]] && name=$func${field:+_$field}
        __bu_out_validate_key "$name" || return 1
        case "$func" in
        count|sum|avg|min|max|first|last|collect) ;;
        *)
            bu_log_err "Unknown aggregate func[$func] in spec[$spec]. Expected one of: count, sum, avg, min, max, first, last, collect"
            return 1
            ;;
        esac
        if [[ "$func" != count ]]
        then
            if [[ -z "$field" ]]
            then
                bu_log_err "Aggregate[$spec] requires a field (e.g. $func:hp)"
                return 1
            fi
            __bu_out_validate_key "$field" || return 1
        fi
        # Note: \$g and \$v are jq variables, they must not be expanded by bash
        case "$func" in
        count)   fragment="(\$g | length)" ;;
        sum)     fragment="(\$g | map(.[\"$field\"]) | map(select(type == \"number\")) | add // 0)" ;;
        avg)     fragment="((\$g | map(.[\"$field\"]) | map(select(type == \"number\"))) as \$v | if (\$v | length) > 0 then (\$v | add) / (\$v | length) else null end)" ;;
        min)     fragment="(\$g | map(.[\"$field\"]) | map(select(. != null)) | min)" ;;
        max)     fragment="(\$g | map(.[\"$field\"]) | map(select(. != null)) | max)" ;;
        first)   fragment="(\$g[0][\"$field\"])" ;;
        last)    fragment="(\$g[-1][\"$field\"])" ;;
        collect) fragment="(\$g | map(.[\"$field\"]))" ;;
        esac
        fragments+="$sep\"$name\": $fragment"
        sep=,
    done

    "$BU_OUT_JQ" -sc --argjson keys "$keys_json" '
        group_by([.[$keys[]]])
        | map( . as $g
            | (reduce ($keys | to_entries[]) as $e ({}; .[$e.value] = $g[0][$e.value]))
            + {'"$fragments"'}
        )
        | .[]
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
bu_complete_delimited()
{
    local delim=,
    local -a options=()

    while (($#))
    do
        case "$1" in
        --delimiter)
            delim=$2
            shift 2
            ;;
        --options)
            shift
            while (($#)) && [[ "$1" != --* ]]
            do
                options+=("$1")
                shift
            done
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
        esac
    done

    local cur_word=${1:-}
    BU_RET=()
    ((${#options[@]})) || return 1

    local prefix=
    local -A used=()
    local last_seg=$cur_word
    if [[ "$cur_word" == *"$delim"* ]]
    then
        prefix=${cur_word%"$delim"*}${delim}
        last_seg=${cur_word##*"$delim"}
        local used_token
        local ifs=$IFS
        IFS="$delim"
        for used_token in ${cur_word%"$delim"*}
        do
            [[ -n "$used_token" ]] && used[$used_token]=1
        done
        IFS=$ifs
    fi

    local opt
    for opt in "${options[@]}"
    do
        [[ -n "${used[$opt]:-}" ]] && continue
        [[ "$opt" == "$last_seg"* ]] && \
            BU_RET+=("${prefix}${opt}")
    done

    ((${#BU_RET[@]})) && return 0 || return 1
}

# ```
# *Description*:
# Generate completions from a Fig spec JSON file.  Walks the spec tree
# matching the command-line tokens against subcommands and options, then
# emits completions for what can come next: subcommands, options, or
# templated arguments (filepaths, folders).
#
# Designed for use with `bu_parse_positional --ret`.
#
# *Params*:
# - `--spec <path>`: Path to a Fig .json spec file
# - remaining arg: the current word (injected by `--ret`)
# - The full command line is read from `COMP_WORDS` / `COMP_CWORD` or
#   from the dynamically-scoped `command_line` array.
#
# *Returns*:
# - `$BU_RET`: Array of completions
# - exit 0 on success, 1 otherwise
#
# *Examples*:
# ```bash
# # In a command script that wraps a Fig-spec'd tool:
# bu_parse_positional $# --ret bu_complete_from_fig --spec "$HOME/.fig/act.json" -- ret-- \
#     --hint "arg"
# ```
# ```
bu_complete_from_fig()
{
    local spec_path=

    while (($#))
    do
        case "$1" in
        --spec)
            spec_path=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
        esac
    done

    [[ -f "$spec_path" ]] || return 1
    local cur_word=${1:-}
    BU_RET=()

    # Build the token list from the command line.  Prefer the dynamically-
    # scoped `command_line` array (set by the fzf completion bindings),
    # otherwise fall back to COMP_WORDS / COMP_CWORD.
    local -a tokens=()
    local token_idx=0
    local i
    if [[ -n "${command_line[*]:-}" ]]
    then
        tokens=("${command_line[@]}")
        # Remove the command name (first token)
        tokens=("${tokens[@]:1}")
        # The last token is the current word; we already have cur_word
        ((${#tokens[@]})) && unset 'tokens[-1]'
    elif [[ -n "${COMP_WORDS[*]:-}" ]]
    then
        tokens=("${COMP_WORDS[@]:1:$COMP_CWORD-1}")
    fi

    # Walk the spec tree: find the deepest matching subcommand node
    local node_json
    node_json=$("$BU_OUT_JQ" -c --argjson tokens "$("$BU_OUT_JQ" -cn --args '$ARGS.positional' -- "${tokens[@]}")" '
    def walk($node; $tokens):
        if ($tokens | length) == 0 then $node
        else
            ($node.subcommands // []) as $subs
            | ($subs | map(select(.name == $tokens[0]))) as $matches
            | if ($matches | length) > 0 then
                walk($matches[0]; $tokens[1:])
              else $node end
        end;
    walk(.; $tokens)
    ' "$spec_path" 2>/dev/null) || return 1

    # Now generate completions from the matched node
    local -a completions=()

    # Check if the previous token is an option that takes arguments with a
    # template; if so, complete files/dirs for that template only.
    local prev_token=
    local prev_has_template=
    if ((${#tokens[@]}))
    then
        prev_token=${tokens[-1]}
        # Find the option in the node where name matches prev_token
        prev_has_template=$("$BU_OUT_JQ" -r --arg pt "$prev_token" '
            [.options[]? | select((.name | if type == "array" then .[] else . end) == $pt)]
            | .[0].args.template? | if type == "array" then .[] else . end // empty
        ' <<<"$node_json" 2>/dev/null)
    fi

    if [[ -n "$prev_has_template" ]]
    then
        # Complete files/dirs for the previous option'\''s template
        local tpl
        for tpl in $prev_has_template
        do
            case "$tpl" in
            filepaths)
                mapfile -t completions < <(compgen -f -- "$cur_word" 2>/dev/null)
                ;;
            folders)
                mapfile -t completions < <(compgen -d -- "$cur_word" 2>/dev/null)
                ;;
            esac
        done
        ((${#completions[@]})) || return 1
        BU_RET=("${completions[@]}")
        return 0
    fi

    # 1. Subcommands
    local sub_names
    sub_names=$("$BU_OUT_JQ" -r '.subcommands[]?.name // empty' <<<"$node_json" 2>/dev/null)
    if [[ -n "$sub_names" ]]
    then
        while IFS= read -r name
        do
            [[ "$name" == "$cur_word"* ]] && completions+=("$name")
        done <<<"$sub_names"
    fi

    # 2. Options (always show alongside subcommands, or alone if cur starts with -)
    local opt_entries
    opt_entries=$("$BU_OUT_JQ" -c '.options[]? // empty' <<<"$node_json" 2>/dev/null)
    if [[ -n "$opt_entries" ]]
    then
        while IFS= read -r opt
        do
            local opt_names
            opt_names=$("$BU_OUT_JQ" -r '.name | if type == "array" then .[] else . end' <<<"$opt" 2>/dev/null)
            while IFS= read -r oname
            do
                [[ -z "$oname" ]] && continue
                [[ "$oname" == "$cur_word"* ]] && completions+=("$oname")
            done <<<"$opt_names"
        done <<<"$opt_entries"
    fi

    # 3. Positional argument templates (only when no subcommand/option match
    #    and we have at least one token, or explicitly when cur starts without -)
    if ((${#completions[@]} == 0)) && [[ ! "$cur_word" == -* ]]
    then
        local arg_templates
        arg_templates=$("$BU_OUT_JQ" -r '.args[]?.template? | if type == "array" then .[] else . end // empty' <<<"$node_json" 2>/dev/null)
        if [[ -n "$arg_templates" ]]
        then
            local tpl
            for tpl in $arg_templates
            do
                case "$tpl" in
                filepaths)
                    local -a files
                    mapfile -t files < <(compgen -f -- "$cur_word" 2>/dev/null)
                    completions+=("${files[@]}")
                    ;;
                folders)
                    local -a dirs
                    mapfile -t dirs < <(compgen -d -- "$cur_word" 2>/dev/null)
                    completions+=("${dirs[@]}")
                    ;;
                esac
            done
        fi
    fi

    ((${#completions[@]})) || return 1
    BU_RET=("${completions[@]}")
    return 0
}

# ```
# *Description*:
# Autocompletion helper for pipeline producer fields.
# Resolves the field names emitted by the upstream producer in a pipeline
# and emits comma-aware completions suitable for --columns, --select, etc.
#
# *Params*:
# - `--dot` (optional flag): Prefix each field with a dot (for jq expressions)
# - `$1`: The current word being completed
#
# *Returns*:
# - `$BU_RET`: Array of completions
# - exit 0 on success, 1 if no producer could be resolved
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

    # 1. Multi-stage pipeline static analysis: walk all stages, track field
    #    propagation through transforms (select-object, query-object, etc.)
    if __bu_out_analyze_pipeline "$producer_str" fields && ((${#fields[@]} > 0))
    then
        : # fields populated by the analyzer
    else
    # 2. Static registry fallback: longest matching producer prefix wins.
    #    This handles pipelines where static analysis bailed (unknown commands)
    #    or where no multi-stage transforms exist.
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
        # 3. Opt-in probing: execute the producer as typed, read the keys of
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

# MARK: Multi-stage pipeline static analysis

# Maps command names to how they transform record fields in a pipeline.
# Values:
#   producer           - emits initial fields (looked up in BU_OUT_PRODUCER_FIELDS)
#   passthrough        - output fields = input fields (where, sort, distinct, format-*, etc.)
#   project            - output fields = parsed from positional field-spec argument (select-object)
#   query              - output fields determined by running the stage with --debug (query-object)
#   recordify_tsv      - output fields = parsed from --columns (convert-from-tsv)
#   recordify_lines    - output field = parsed from --column (convert-from-lines)
#   recordify_new      - output fields = keys from key=value pairs (new-record)
declare -A -g BU_OUT_STAGE_EFFECT=(
    ["bu get-command"]=producer
    ["bu get-module"]=producer
    ["bu where-object"]=passthrough
    ["bu sort-object"]=passthrough
    ["bu distinct-object"]=passthrough
    ["bu format-table"]=passthrough
    ["bu format-list"]=passthrough
    ["bu convert-to-json"]=passthrough
    ["bu convert-to-jsonl"]=passthrough
    ["bu convert-to-tsv"]=passthrough
    ["bu out-default"]=passthrough
    ["bu select-object"]=project
    ["bu query-object"]=query
    ["bu convert-from-tsv"]=recordify_tsv
    ["bu convert-from-lines"]=recordify_lines
    ["bu new-record"]=recordify_new
    ["bu convert-from-jc"]=recordify_jc
    ["bu get-npm-package"]=producer
    ["bu get-npm-outdated"]=producer
    ["bu get-pnpm-package"]=producer
    ["bu get-pgrep-process"]=producer
    ["bu get-npm-audit"]=producer
    ["bu get-pnpm-outdated"]=producer
    ["bu get-docker-container"]=producer
    ["bu get-docker-image"]=producer
    ["bu get-docker-volume"]=producer
    ["bu get-docker-network"]=producer
    ["bu get-file"]=producer
    ["bu get-process"]=producer
    ["bu get-disk"]=producer
    ["bu get-dns"]=producer
    ["bu get-memory"]=producer
    ["bu get-mount"]=producer
    ["bu get-uptime"]=producer
    ["bu get-system"]=producer
    ["bu get-environment"]=producer
    ["bu get-identity"]=producer
    ["bu get-file-usage"]=producer
    ["bu get-file-stat"]=producer
    ["bu get-interface"]=producer
    ["bu get-socket"]=producer
    ["bu get-network"]=producer
    ["bu get-arp-entry"]=producer
    ["bu get-cpu-stat"]=producer
    ["bu get-memory-stat"]=producer
    ["bu get-open-file"]=producer
    ["bu get-count"]=producer
    ["bu get-dpkg-package"]=producer
)

# ```
# *Description*:
# Register a command's pipeline stage effect for static field analysis.
#
# *Params*:
# - `$1`: Command name (e.g. `bu get-command`, `bu select-object`)
# - `$2`: Effect type: producer, passthrough, project, query, recordify_tsv,
#         recordify_lines, recordify_new
#
# *Examples*:
# ```bash
# bu_register_stage_effect "bu get-command" producer
# bu_register_stage_effect "bu where-object" passthrough
# bu_register_stage_effect "bu select-object" project
# ```
# ```
bu_register_stage_effect()
{
    local -r cmd=$1
    local -r effect=$2
    if [[ -z "$cmd" || -z "$effect" ]]
    then
        bu_log_err "Usage: bu_register_stage_effect <command> <effect>"
        return 1
    fi
    BU_OUT_STAGE_EFFECT[$cmd]=$effect
}

# ```
# *Description*:
# Split a pipeline text (everything before the cursor's pipe) into individual
# stage texts. Uses `|` as the delimiter. The text comes from tree-sitter's
# pipeBefore, which is already CST-accurate — pipes inside strings or
# subshells are excluded.
#
# *Params*:
# - `$1`: Pipeline text (e.g. "bu get-command | bu select-object name")
# - nameref `$2`: Output array of trimmed stage texts
# ```
__bu_out_split_pipeline()
{
    local pipeline_text=$1
    local -n out_stages=$2
    out_stages=()

    [[ -z "$pipeline_text" ]] && return 0

    local -a raw=()
    local ifs=$IFS
    IFS='|'
    # shellcheck disable=SC2206 # Intentional word splitting on pipe
    raw=($pipeline_text)
    IFS=$ifs

    local stage
    for stage in "${raw[@]}"
    do
        # Trim leading/trailing whitespace
        stage=${stage#"${stage%%[![:space:]]*}"}
        stage=${stage%"${stage##*[![:space:]]}"}
        [[ -n "$stage" ]] && out_stages+=("$stage")
    done
}

# ```
# *Description*:
# Extract the command name from a pipeline stage text. Handles multi-word
# verbs (BU_MULTI_WORD_VERBS) so "bu convert-from-tsv --columns a,b" returns
# "bu convert-from-tsv".
#
# *Params*:
# - `$1`: Stage text
#
# *Returns*:
# - stdout: The resolved command name
# ```
__bu_out_extract_command()
{
    local stage_text=$1
    [[ -z "$stage_text" ]] && return 1

    # Split into words
    local -a words=()
    # shellcheck disable=SC2206 # Intentional word splitting
    words=($stage_text)
    ((${#words[@]} == 0)) && return 1

    local cmd_name=${words[0]}

    # bu commands are always "bu <verb-noun>" (two words).
    # Multi-word verbs like "convert-from" make the noun start later,
    # but the command is still exactly two words.
    if [[ "$cmd_name" == bu ]] && ((${#words[@]} >= 2))
    then
        cmd_name="$cmd_name ${words[1]}"
    fi

    printf '%s' "$cmd_name"
}

# ```
# *Description*:
# Parse the output field names from a select-object stage's field spec.
# Handles "new=old" rename syntax — keeps the "new" (left-hand) names.
#
# *Params*:
# - `$1`: Stage text (e.g. "bu select-object name,ver=version --unique")
# - nameref `$2`: Output array of field names
# ```
__bu_out_parse_select_fields()
{
    local stage_text=$1
    local -n out_fields=$2
    out_fields=()

    local -a words=()
    # shellcheck disable=SC2206
    words=($stage_text)
    ((${#words[@]} < 2)) && return 1

    # Determine how many leading words form the command name.
    # bu commands are always two words (bu + verb-noun); others are one word.
    local cmd_word_count=1
    if [[ "${words[0]}" == bu ]] && ((${#words[@]} >= 2))
    then
        cmd_word_count=2
    fi

    # Find the first non-flag word after the command name — that's the field spec
    local i word field_spec=
    for (( i = cmd_word_count; i < ${#words[@]}; i++ ))
    do
        word=${words[i]}
        [[ "$word" == -* ]] && continue
        field_spec=$word
        break
    done

    [[ -z "$field_spec" ]] && return 1

    # Parse comma-separated specs: "new=old" → "new", "field" → "field"
    local spec new_name
    local ifs=$IFS
    IFS=','
    for spec in $field_spec
    do
        [[ -z "$spec" ]] && continue
        case "$spec" in
        *=*) new_name=${spec%%=*} ;;
        *)   new_name=$spec ;;
        esac
        out_fields+=("$new_name")
    done
    IFS=$ifs
}

# ```
# *Description*:
# Analyze a single pipeline stage: given its text and the input field names,
# compute the output field names after this stage executes.
#
# *Params*:
# - `$1`: Stage text
# - nameref `$2`: Input field names array
# - nameref `$3`: Output field names array (set by this function)
#
# *Returns*:
# - 0 on success, 1 if the stage effect is unknown and analysis should bail
# ```
__bu_out_analyze_stage()
{
    local stage_text=$1
    local -n _in_fields=$2
    local -n _out_fields=$3
    _out_fields=()

    local cmd_name
    cmd_name=$(__bu_out_extract_command "$stage_text") || return 1

    # Look up effect: longest prefix match on stage text so flags don't break it
    local effect=
    local key best_key=
    for key in "${!BU_OUT_STAGE_EFFECT[@]}"
    do
        if [[ "$stage_text" == "$key" || "$stage_text" == "$key "* ]] && (( ${#key} > ${#best_key} ))
        then
            best_key=$key
        fi
    done
    if [[ -n "$best_key" ]]
    then
        effect=${BU_OUT_STAGE_EFFECT[$best_key]}
    fi
    if [[ -z "$effect" ]]
    then
        return 1
    fi

    case "$effect" in
    producer)
        # Look up static field registry
        local best_producer=
        for key in "${!BU_OUT_PRODUCER_FIELDS[@]}"
        do
            if [[ "$stage_text" == "$key" || "$stage_text" == "$key "* ]] && (( ${#key} > ${#best_producer} ))
            then
                best_producer=$key
            fi
        done
        if [[ -n "$best_producer" ]]
        then
            # shellcheck disable=SC2206
            _out_fields=(${BU_OUT_PRODUCER_FIELDS[$best_producer]})
        fi
        ;;
    passthrough)
        _out_fields=("${_in_fields[@]}")
        ;;
    project)
        __bu_out_parse_select_fields "$stage_text" _out_fields || _out_fields=("${_in_fields[@]}")
        ;;
    query)
        # Run the stage with --debug appended to get the query plan.
        # This is safe: --debug only parses arguments, doesn't read stdin or
        # execute jq expressions. Uses eval on CST-vetted text (same trust
        # boundary as the existing probing system).
        if [[ -n "$BU_OUT_JQ" ]]
        then
            local debug_out
            debug_out=$(eval "$stage_text --debug" 2>/dev/null) || true
            if [[ -n "$debug_out" ]]
            then
                local output_fields_json
                output_fields_json=$("$BU_OUT_JQ" -r '.outputFields // empty' <<<"$debug_out" 2>/dev/null) || true
                if [[ -n "$output_fields_json" && "$output_fields_json" != null ]]
                then
                    local parsed
                    parsed=$("$BU_OUT_JQ" -r '.[]' <<<"$output_fields_json" 2>/dev/null) || true
                    [[ -n "$parsed" ]] && mapfile -t _out_fields <<<"$parsed"
                fi
            fi
        fi
        # If we couldn't determine output fields (passthrough query), inherit input
        if ((${#_out_fields[@]} == 0))
        then
            _out_fields=("${_in_fields[@]}")
        fi
        ;;
    recordify_tsv)
        # Parse --columns from stage text
        local cols=
        if [[ "$stage_text" =~ --columns[[:space:]]+([^[:space:]]+) ]]
        then
            cols=${BASH_REMATCH[1]}
            cols=${cols%,}  # strip trailing comma if present
            local c new_name
            local ifs=$IFS
            IFS=','
            for c in $cols
            do
                [[ -z "$c" ]] && continue
                case "$c" in
                *:*) new_name=${c%%:*} ;;  # key:Label → key
                *)   new_name=$c ;;
                esac
                _out_fields+=("$new_name")
            done
            IFS=$ifs
        fi
        ;;
    recordify_lines)
        # Parse --column from stage text
        if [[ "$stage_text" =~ --column[[:space:]]+([^[:space:]]+) ]]
        then
            _out_fields=("${BASH_REMATCH[1]}")
        fi
        ;;
    recordify_new)
        # Parse key=value pairs: keys become output fields
        local -a rwords=()
        # shellcheck disable=SC2206
        rwords=($stage_text)
        local rword rkey
        for rword in "${rwords[@]}"
        do
            [[ "$rword" == -* ]] && continue
            [[ "$rword" == "${rwords[0]}" ]] && continue  # skip cmd name
            if [[ "$rword" == *=* && "$rword" != *:=* ]]
            then
                rkey=${rword%%=*}
                _out_fields+=("$rkey")
            elif [[ "$rword" == *:=* ]]
            then
                rkey=${rword%%:=*}
                _out_fields+=("$rkey")
            fi
        done
        ;;
    recordify_jc)
        # bu convert-from-jc: extract the parser name and look up the static
        # field map. Falls back to --discover if not found statically.
        local jc_parser=
        if [[ "$stage_text" =~ --parser[[:space:]]+([^[:space:]]+) ]]
        then
            jc_parser=${BASH_REMATCH[1]}
        fi
        if [[ -n "$jc_parser" ]]
        then
            # Look up in the static field map (registered with prefix matching)
            local jc_key="bu convert-from-jc --parser $jc_parser"
            local -a jc_fields=()
            # shellcheck disable=SC2206
            jc_fields=(${BU_OUT_PRODUCER_FIELDS[$jc_key]:-})
            if ((${#jc_fields[@]} > 0))
            then
                _out_fields=("${jc_fields[@]}")
            elif [[ -n "$BU_OUT_JQ" ]]
            then
                # Fall back to --discover (runs a sample invocation)
                local debug_out
                debug_out=$(eval "$stage_text --discover" 2>/dev/null) || true
                if [[ -n "$debug_out" ]]
                then
                    local output_fields_json
                    output_fields_json=$("$BU_OUT_JQ" -r '.outputFields // empty' <<<"$debug_out" 2>/dev/null) || true
                    if [[ -n "$output_fields_json" && "$output_fields_json" != null ]]
                    then
                        local parsed
                        parsed=$("$BU_OUT_JQ" -r '.[]' <<<"$output_fields_json" 2>/dev/null) || true
                        [[ -n "$parsed" ]] && mapfile -t _out_fields <<<"$parsed"
                    fi
                fi
            fi
        fi
        ;;
    *)
        # Unknown command — bail out, can't statically analyze
        return 1
        ;;
    esac

    return 0
}

# ```
# *Description*:
# Analyze a full pipeline (everything before the cursor's pipe) and compute
# the record fields available at the current stage. Walks each stage in
# order, tracking field propagation through transforms.
#
# *Params*:
# - `$1`: Pipeline text (pipe_before, with or without trailing pipe)
# - nameref `$2`: Output array of field names
#
# *Returns*:
# - 0 if analysis succeeded (fields populated), 1 if the pipeline contains
#   unknown/unsupported commands and static analysis must bail
#
# *Notes*:
# - The first stage must be a producer (has entry in BU_OUT_PRODUCER_FIELDS)
#   or the pipeline can't be statically analyzed.
# - If any stage returns unknown, the whole analysis bails.
# ```
__bu_out_analyze_pipeline()
{
    local pipeline_text=$1
    local -n _final_fields=$2
    _final_fields=()

    # Trim trailing pipe character and whitespace
    pipeline_text=${pipeline_text%"${pipeline_text##*[![:space:]]}"}
    pipeline_text=${pipeline_text%|}
    pipeline_text=${pipeline_text%"${pipeline_text##*[![:space:]]}"}

    [[ -z "$pipeline_text" ]] && return 1

    local -a stages=()
    __bu_out_split_pipeline "$pipeline_text" stages
    ((${#stages[@]} == 0)) && return 1

    local -a current_fields=()
    local -a next_fields=()
    local stage
    for stage in "${stages[@]}"
    do
        if ! __bu_out_analyze_stage "$stage" current_fields next_fields
        then
            return 1
        fi
        current_fields=("${next_fields[@]}")
    done

    ((${#current_fields[@]} == 0)) && return 1
    _final_fields=("${current_fields[@]}")
    return 0
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

    # Auto-colour table columns on a terminal when no explicit --colors given
    if [[ -z "$colors" && "$format" == table && -t 1 ]]
    then
        colors=auto
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
