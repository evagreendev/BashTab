# bash-ide source=./bu_core_base.sh
# bash-ide source=./bu_core_out.sh

# MARK: Interactive table viewer (bu tv)
#
# A pure-Bash TUI table viewer for JSONL streams.  Provides fixed headers,
# column-aware horizontal scrolling, interactive sort, search, and terminal
# resize handling — all with vim/less keybindings.
#
# Pipe any JSONL stream into it:
#     bu get-command | bu tv
#     bu get-command | bu tv --colors auto
#     bu get-command | bu tv --columns name,type

# ── Terminal escape sequences (computed once at source time) ─────────────
declare -g -r __BU_TV_ESC=$'\e'
declare -g -r __BU_TV_ALT_SCREEN_ON="${__BU_TV_ESC}[?1049h"
declare -g -r __BU_TV_ALT_SCREEN_OFF="${__BU_TV_ESC}[?1049l"
declare -g -r __BU_TV_CURSOR_HOME="${__BU_TV_ESC}[H"
declare -g -r __BU_TV_CURSOR_HIDE="${__BU_TV_ESC}[?25l"
declare -g -r __BU_TV_CURSOR_SHOW="${__BU_TV_ESC}[?25h"
declare -g -r __BU_TV_CLEAR_SCREEN="${__BU_TV_ESC}[2J"
declare -g -r __BU_TV_CLEAR_LINE="${__BU_TV_ESC}[K"
declare -g -r __BU_TV_REVERSE="${__BU_TV_ESC}[7m"
declare -g -r __BU_TV_REVERSE_OFF="${__BU_TV_ESC}[27m"
declare -g -r __BU_TV_DIM="${__BU_TV_ESC}[2m"
declare -g -r __BU_TV_RESET="${BU_TPUT_RESET:-${__BU_TV_ESC}[0m}"
declare -g -r __BU_TV_BOLD="${BU_TPUT_BOLD:-${__BU_TV_ESC}[1m}"

# ── State ────────────────────────────────────────────────────────────────
declare -g -a _TV_ROWS=()           # Raw JSON strings, one per record
declare -g -a _TV_COLUMNS=()        # Column keys (e.g. name, version)
declare -g -a _TV_HEADERS=()        # Display labels (parsed from key:Label)
declare -g -A _TV_COLORS=()         # key → ANSI escape code (or empty)
declare -g -a _TV_CELLS=()          # Flat cell cache: [row * ncols + col] → string value
declare -g -i _TV_NUM_ROWS=0
declare -g -i _TV_NUM_COLS=0
declare -g -a _TV_COL_WIDTHS=()     # Content-based width per column (capped)
declare -g -i _TV_ROW_OFFSET=0      # First visible row (0-indexed)
declare -g -i _TV_COL_OFFSET=0      # First visible column (0-indexed)
declare -g    _TV_SORT_COL=         # Column key for sort, empty = unsorted
declare -g    _TV_SORT_DIR=         # "asc" or "desc"
declare -g    _TV_SEARCH_QUERY=     # Current search string
declare -g -a _TV_MATCHED_ROWS=()   # Indices of rows matching _TV_SEARCH_QUERY
declare -g -i _TV_MATCH_IDX=-1      # Current position in _TV_MATCHED_ROWS
declare -g -i _TV_TERM_ROWS=24
declare -g -i _TV_TERM_COLS=80
declare -g -i _TV_HIGHLIGHT_COL=0   # Leftmost visible column index (for sort hint)
declare -g    _TV_SAVED_STTY=       # Saved stty settings for cleanup

# ── Helpers ──────────────────────────────────────────────────────────────

# ```
# *Description*:
# Read all JSONL from stdin into _TV_ROWS.  Skips blank lines.
#
# *Returns*:
# - Sets _TV_ROWS[] and _TV_NUM_ROWS.  _TV_NUM_ROWS = 0 on empty input.
# ```
__bu_tv_read_stdin()
{
    _TV_ROWS=()
    _TV_NUM_ROWS=0
    local line
    while IFS= read -r line || [[ -n "$line" ]]
    do
        [[ -z "$line" ]] && continue
        _TV_ROWS+=("$line")
        _TV_NUM_ROWS=$((_TV_NUM_ROWS + 1))
    done
}

# ```
# *Description*:
# Extract column keys and display labels.
#
# *Params*:
# - `$1`: Optional comma-separated column spec (key:Label,...).
#         Empty → auto-detect from first record's keys.
#
# *Returns*:
# - Sets _TV_COLUMNS[], _TV_HEADERS[], _TV_NUM_COLS.
# ```
__bu_tv_extract_columns()
{
    local spec=$1
    _TV_COLUMNS=()
    _TV_HEADERS=()
    _TV_NUM_COLS=0

    if [[ -n "$spec" ]]
    then
        __bu_out_colspecs_to_json "$spec" || return 1
        local key header
        while IFS=$'\t' read -r key header
        do
            _TV_COLUMNS+=("$key")
            _TV_HEADERS+=("$header")
            _TV_NUM_COLS=$((_TV_NUM_COLS + 1))
        done < <("$BU_OUT_JQ" -r '.[] | "\(.key)\t\(.header)"' <<<"$BU_RET")
    elif (( _TV_NUM_ROWS > 0 ))
    then
        local key
        while IFS= read -r key
        do
            _TV_COLUMNS+=("$key")
            _TV_HEADERS+=("$key")
            _TV_NUM_COLS=$((_TV_NUM_COLS + 1))
        done < <("$BU_OUT_JQ" -r 'keys_unsorted[]' <<<"${_TV_ROWS[0]}")
    fi
}

# ```
# *Description*:
# Rebuild the cell cache and recompute column widths.  Uses a single jq
# invocation for all cell extraction, then computes widths in bash from
# the cached values.
#
# *Params*:
# - None.  Reads _TV_ROWS[], _TV_COLUMNS[], _TV_NUM_ROWS, _TV_NUM_COLS.
#
# *Returns*:
# - Sets _TV_CELLS[] and _TV_COL_WIDTHS[].
# ```
__bu_tv_rebuild_cache()
{
    _TV_CELLS=()
    _TV_COL_WIDTHS=()
    if (( _TV_NUM_ROWS == 0 || _TV_NUM_COLS == 0 ))
    then
        return
    fi

    # ── Build jq arg list and expression ──────────────────────────────
    local -a jq_args=()
    local jq_keys= sep=
    local -i j
    for (( j = 0; j < _TV_NUM_COLS; j++ ))
    do
        local col_key="${_TV_COLUMNS[$j]}"
        jq_args+=('--arg' "c$j" "$col_key")
        jq_keys+="$sep.[\$c$j]"
        sep=,
    done

    # ── Extract cells and compute widths in a single jq pass ─────────
    local jq_expr
    printf -v jq_expr '[%s] | map(. // "" | tostring) | @tsv' "$jq_keys"

    local -a raw_output=()
    local line
    while IFS= read -r line
    do
        raw_output+=("$line")
    done < <(printf '%s\n' "${_TV_ROWS[@]}" | "$BU_OUT_JQ" -r "${jq_args[@]}" "$jq_expr")

    # ── Parse TSV into _TV_CELLS ─────────────────────────────────────
    local old_ifs=$IFS
    local -i i
    for (( i = 0; i < _TV_NUM_ROWS; i++ ))
    do
        IFS=$'\t' read -r -a line <<<"${raw_output[$i]}"
        _TV_CELLS+=("${line[@]}")
    done
    IFS=$old_ifs

    # ── Compute widths: max of header length and each cell length ────
    local -i wid max_width=40
    local cell_val
    for (( j = 0; j < _TV_NUM_COLS; j++ ))
    do
        wid=${#_TV_HEADERS[$j]}
        for (( i = 0; i < _TV_NUM_ROWS; i++ ))
        do
            cell_val=${_TV_CELLS[$((i * _TV_NUM_COLS + j))]}
            if (( ${#cell_val} > wid )); then wid=${#cell_val}; fi
        done
        if (( wid < 4 )); then wid=4; fi
        if (( wid > max_width )); then wid=$max_width; fi
        _TV_COL_WIDTHS+=($wid)
    done
}

# ```
# *Description*:
# Fetch a cached cell value.  No jq fork — pure array lookup.
#
# *Params*:
# - `$1`: Row index (0-indexed)
# - `$2`: Column index (0-indexed)
#
# *Returns*:
# - stdout: Cell value string
# ```
__bu_tv_get_cell()
{
    local -i row=$1 col=$2
    printf '%s' "${_TV_CELLS[$((row * _TV_NUM_COLS + col))]:-}"
}

# ```
# *Description*:
# Build a colors map from a --colors spec or "auto" rainbow.
#
# *Params*:
# - `$1`: Color spec string (same as bu_format_table --colors)
#
# *Returns*:
# - Sets _TV_COLORS assoc array.
# ```
__bu_tv_build_colors()
{
    local spec=$1
    _TV_COLORS=()
    [[ -z "$spec" ]] && return 0

    if [[ "$spec" == auto ]]
    then
        local -i i
        local cname cvar
        for (( i = 0; i < _TV_NUM_COLS; i++ ))
        do
            cname=${__BU_OUT_RAINBOW[$((i % ${#__BU_OUT_RAINBOW[@]}))]}
            cvar=BU_TPUT_${cname^^}
            _TV_COLORS["${_TV_COLUMNS[$i]}"]=${!cvar}
        done
    else
        __bu_out_colors_to_json "$spec" || return 1
        local key ansi
        while IFS=$'\t' read -r key ansi
        do
            _TV_COLORS["$key"]=$ansi
        done < <("$BU_OUT_JQ" -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$BU_RET")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Terminal management
# ═══════════════════════════════════════════════════════════════════════════

# ```
# *Description*:
# Enter raw terminal mode: alternate screen, hide cursor, non-canonical
# input, trap SIGWINCH and cleanup signals.
# ```
__bu_tv_terminal_setup()
{
    _TV_SAVED_STTY=$(stty -g 2>/dev/null) || _TV_SAVED_STTY=
    stty -echo -icanon 2>/dev/null || true

    printf '%s' "$__BU_TV_ALT_SCREEN_ON"
    printf '%s' "$__BU_TV_CURSOR_HIDE"
    printf '%s%s' "$__BU_TV_CURSOR_HOME" "$__BU_TV_CLEAR_SCREEN"

    __bu_tv_update_dimensions

    trap '__bu_tv_terminal_restore; exit 0' SIGINT SIGTERM
    trap '__bu_tv_cleanup_exit' EXIT
    trap '__bu_tv_on_resize' SIGWINCH
}

# ```
# *Description*:
# Restore terminal to its original state on exit.
# ```
__bu_tv_terminal_restore()
{
    trap - SIGINT SIGTERM SIGWINCH EXIT

    printf '%s' "$__BU_TV_CURSOR_SHOW"
    printf '%s' "$__BU_TV_ALT_SCREEN_OFF"

    if [[ -n "$_TV_SAVED_STTY" ]]
    then
        stty "$_TV_SAVED_STTY" 2>/dev/null || true
    fi
}

# ```
# *Description*:
# EXIT trap handler — delegates to terminal restore.
# ```
__bu_tv_cleanup_exit()
{
    __bu_tv_terminal_restore
}

# ```
# *Description*:
# Update _TV_TERM_ROWS and _TV_TERM_COLS from current terminal size.
# ```
__bu_tv_update_dimensions()
{
    _TV_TERM_COLS=80
    _TV_TERM_ROWS=24
    [[ -n "${COLUMNS:-}" ]] && _TV_TERM_COLS=$COLUMNS
    [[ -n "${LINES:-}" ]] && _TV_TERM_ROWS=$LINES
    local tc tl
    tc=$(tput cols 2>/dev/null) && [[ -n "$tc" ]] && _TV_TERM_COLS=$tc
    tl=$(tput lines 2>/dev/null) && [[ -n "$tl" ]] && _TV_TERM_ROWS=$tl
    if (( _TV_TERM_COLS < 20 )); then _TV_TERM_COLS=80; fi
    if (( _TV_TERM_ROWS < 10 )); then _TV_TERM_ROWS=24; fi
}

# ```
# *Description*:
# SIGWINCH handler — recompute dimensions, clamp offsets, redraw.
# ```
__bu_tv_on_resize()
{
    __bu_tv_update_dimensions
    __bu_tv_clamp_offsets
    __bu_tv_render_frame
}

# ── Navigation / offset clamping ─────────────────────────────────────────

# ```
# *Description*:
# Clamp _TV_ROW_OFFSET and _TV_COL_OFFSET to valid ranges.
# ```
__bu_tv_clamp_offsets()
{
    local -i data_rows=$((_TV_TERM_ROWS - 3))
    (( data_rows < 1 )) && data_rows=1

    local -i max_row=$((_TV_NUM_ROWS - data_rows))
    (( max_row < 0 )) && max_row=0
    (( _TV_ROW_OFFSET > max_row )) && _TV_ROW_OFFSET=$max_row
    (( _TV_ROW_OFFSET < 0 )) && _TV_ROW_OFFSET=0

    # Walk column offset rightward until at least one column is visible
    if (( _TV_NUM_COLS > 0 ))
    then
        local -i j used
        while (( _TV_COL_OFFSET < _TV_NUM_COLS ))
        do
            used=0
            for (( j = _TV_COL_OFFSET; j < _TV_NUM_COLS; j++ ))
            do
                used=$((used + _TV_COL_WIDTHS[$j] + 2))
            done
            (( used > 0 )) && break
            _TV_COL_OFFSET=$((_TV_COL_OFFSET + 1))
        done
        # Walk left if there's unused space
        while (( _TV_COL_OFFSET > 0 ))
        do
            used=0
            local try_start=$((_TV_COL_OFFSET - 1))
            for (( j = try_start; j < _TV_NUM_COLS; j++ ))
            do
                used=$((used + _TV_COL_WIDTHS[$j] + 2))
            done
            (( used > _TV_TERM_COLS )) && break
            _TV_COL_OFFSET=$try_start
        done
    fi
    (( _TV_COL_OFFSET < 0 )) && _TV_COL_OFFSET=0
}

# ═══════════════════════════════════════════════════════════════════════════
# Rendering
# ═══════════════════════════════════════════════════════════════════════════

# ```
# *Description*:
# Get the list of column indices visible in the current viewport.
#
# *Returns*:
# - stdout: Space-separated column indices
# ```
__bu_tv_visible_cols()
{
    local -i j used=0
    for (( j = _TV_COL_OFFSET; j < _TV_NUM_COLS; j++ ))
    do
        (( used + _TV_COL_WIDTHS[$j] + 2 > _TV_TERM_COLS )) && break
        printf '%d ' $j
        used=$((used + _TV_COL_WIDTHS[$j] + 2))
    done
}

# ```
# *Description*:
# Highlight occurrences of a query string within text using reverse video.
# Case-insensitive.  Uses sed for the actual replacement.
#
# *Params*:
# - `$1`: Text to search in
# - `$2`: Query string
#
# *Returns*:
# - stdout: Text with matches wrapped in reverse-video ANSI codes
# ```
__bu_tv_highlight_in_text()
{
    local text=$1 query=$2
    if [[ -z "$query" || -z "$text" ]]
    then
        printf '%s' "$text"
        return
    fi
    local escaped
    escaped=$(printf '%s' "$query" | sed 's/[.[\*^$()+?{|]/\\&/g')
    printf '%s' "$text" | sed "s/\\($escaped\\)/${__BU_TV_REVERSE}\\1${__BU_TV_REVERSE_OFF}/gI"
}

# ```
# *Description*:
# Build a formatted cell string for a single data cell.
# Applies color, search highlighting, truncation+ellipsis, and padding.
#
# *Params*:
# - `$1`: Row index
# - `$2`: Column index
#
# *Returns*:
# - stdout: Formatted cell string (with ANSI codes), exact column width
# ```
__bu_tv_format_cell()
{
    local -i row_idx=$1 col_idx=$2
    local -i col_w=${_TV_COL_WIDTHS[$col_idx]}
    local key=${_TV_COLUMNS[$col_idx]}

    # Get raw cell value from cache (no jq fork)
    local raw
    raw=$(__bu_tv_get_cell $row_idx $col_idx)

    # Truncate with ellipsis if needed
    local display="$raw"
    local -i raw_len=${#raw}
    if (( raw_len > col_w ))
    then
        display="${raw:0:$((col_w - 1))}…"
    fi

    # Search highlighting
    if [[ -n "$_TV_SEARCH_QUERY" ]]
    then
        display=$(__bu_tv_highlight_in_text "$display" "$_TV_SEARCH_QUERY")
    fi

    # Color prefix
    local color=${_TV_COLORS[$key]:-}
    if [[ -n "$color" ]]
    then
        printf '%s%s%s' "$color" "$display" "$__BU_TV_RESET"
    else
        printf '%s' "$display"
    fi
}

# ```
# *Description*:
# Render a single table line (header, separator, or data row).
#
# *Params*:
# - `$1`: Row index (-1 = header, -2 = separator, >= 0 = data row)
# - `$2`: "true" if this row should be highlighted as the current search match
#
# *Returns*:
# - stdout: Formatted row string, right-trimmed
# ```
__bu_tv_render_line()
{
    local -i row_idx=$1
    local is_current_match=$2
    local -a vis_cols=()
    local col_idx
    # Collect visible column indices
    for col_idx in $(__bu_tv_visible_cols)
    do
        vis_cols+=($col_idx)
    done

    local line= sep=
    local -i j
    for j in "${vis_cols[@]}"
    do
        local -i col_w=${_TV_COL_WIDTHS[$j]}
        if (( row_idx == -1 ))
        then
            # Header
            local hdr=${_TV_HEADERS[$j]}
            local -i hdr_len=${#hdr}
            if (( hdr_len > col_w ))
            then
                hdr="${hdr:0:$((col_w - 1))}…"
                hdr_len=$((col_w - 1))
            fi
            local pad=$((col_w - hdr_len))
            local spacer=
            local -i k
            for (( k = 0; k < pad; k++ )); do spacer+=' '; done
            line+="$sep${__BU_TV_ESC}[1m${hdr}${__BU_TV_ESC}[0m${spacer}"
        elif (( row_idx == -2 ))
        then
            # Separator
            local sep_line=
            local -i k
            for (( k = 0; k < col_w; k++ )); do sep_line+='-'; done
            line+="$sep$sep_line"
        else
            # Data row
            local cell
            cell=$(__bu_tv_format_cell $row_idx $j)

            # Measure visible width (strip ANSI)
            local stripped="$cell"
            while [[ $stripped =~ $'\e'\[[0-9\;]*[a-zA-Z] ]]
            do
                stripped=${stripped//"${BASH_REMATCH[0]}"/}
            done
            local -i cell_len=${#stripped}
            local pad=$((col_w - cell_len))
            local spacer=
            local -i k
            for (( k = 0; k < pad; k++ )); do spacer+=' '; done

            if "$is_current_match" && (( _TV_MATCH_IDX >= 0 ))
            then
                line+="$sep${__BU_TV_REVERSE}${cell}${spacer}${__BU_TV_REVERSE_OFF}"
            else
                line+="$sep${cell}${spacer}"
            fi
        fi
        sep='  '
    done
    # Right-trim trailing spaces
    line=${line%"${line##*[! ]}"}
    printf '%s' "$line"
}

# ```
# *Description*:
# Check if a row index is the current search match.
# ```
__bu_tv_is_current_match()
{
    local -i row_idx=$1
    (( _TV_MATCH_IDX < 0 )) && return 1
    (( _TV_MATCH_IDX >= ${#_TV_MATCHED_ROWS[@]} )) && return 1
    local -i match_row=${_TV_MATCHED_ROWS[$_TV_MATCH_IDX]}
    (( match_row == row_idx ))
}

# ```
# *Description*:
# Full frame render: header, separator, data rows, status line.
# ```
__bu_tv_render_frame()
{
    # Screen layout:
    #   row 1          = header
    #   row 2          = separator
    #   rows 3..N-1    = data (TERM_ROWS - 3 rows)
    #   row N (bottom) = status line
    #
    # Each row is drawn with absolute cursor positioning and \e[K
    # (clear-to-EOL) — no newlines anywhere, so the terminal can never
    # scroll and push the header off-screen.
    local -i data_rows=$((_TV_TERM_ROWS - 3))
    (( data_rows < 1 )) && data_rows=1

    local frame=

    # Header (row 1)
    local header_line
    header_line=$(__bu_tv_render_line -1 false)
    printf -v frame '%s\e[1;1H%s\e[K' "$frame" "$header_line"

    # Separator (row 2)
    local sep_line
    sep_line=$(__bu_tv_render_line -2 false)
    printf -v frame '%s\e[2;1H%s\e[K' "$frame" "$sep_line"

    # Data rows (rows 3..N-1)
    local -i i
    for (( i = 0; i < data_rows; i++ ))
    do
        local -i row_idx=$((_TV_ROW_OFFSET + i))
        local -i screen_row=$((i + 3))
        if (( row_idx >= _TV_NUM_ROWS ))
        then
            printf -v frame '%s\e[%d;1H\e[K' "$frame" "$screen_row"
        else
            local is_match=false
            __bu_tv_is_current_match $row_idx && is_match=true
            local row_line
            row_line=$(__bu_tv_render_line $row_idx "$is_match")
            printf -v frame '%s\e[%d;1H%s\e[K' "$frame" "$screen_row" "$row_line"
        fi
    done

    # Status line (bottom row) — absolute position, no trailing newline
    local status
    status=$(__bu_tv_render_status)
    printf -v frame '%s\e[%d;1H%s\e[K' "$frame" "$_TV_TERM_ROWS" "$status"

    printf '%s' "$frame"
}

# ```
# *Description*:
# Build the status line string.
# ```
__bu_tv_render_status()
{
    local -a parts=()

    # Row position
    local -i last_visible=$((_TV_ROW_OFFSET + _TV_TERM_ROWS - 3))
    (( last_visible >= _TV_NUM_ROWS )) && last_visible=$((_TV_NUM_ROWS - 1))
    if (( _TV_NUM_ROWS > 0 ))
    then
        parts+=("Rows $((_TV_ROW_OFFSET + 1))-$((last_visible + 1))/${_TV_NUM_ROWS}")
    else
        parts+=("No data")
    fi

    # Column info
    if (( _TV_NUM_COLS > 0 ))
    then
        local col_name=${_TV_COLUMNS[$_TV_COL_OFFSET]:-}
        parts+=("Col $((_TV_COL_OFFSET + 1))/${_TV_NUM_COLS} [$col_name]")
    fi

    # Sort info
    if [[ -n "$_TV_SORT_COL" ]]
    then
        local arrow='↑'
        [[ "$_TV_SORT_DIR" == desc ]] && arrow='↓'
        parts+=("Sorted: ${_TV_SORT_COL} $arrow")
    fi

    # Search info
    if [[ -n "$_TV_SEARCH_QUERY" ]]
    then
        local match_info
        if (( ${#_TV_MATCHED_ROWS[@]} > 0 ))
        then
            match_info="$((_TV_MATCH_IDX + 1))/${#_TV_MATCHED_ROWS[@]}"
        else
            match_info="0/0"
        fi
        parts+=("Search: \"${_TV_SEARCH_QUERY}\" [$match_info]")
    fi

    # Key hints
    parts+=("q:quit /:search s:sort n:next")

    # Join
    local sep=' │ '
    local result=
    local first=true
    local part
    for part in "${parts[@]}"
    do
        if "$first"
        then
            result="$part"
            first=false
        else
            result+="$sep$part"
        fi
    done

    # Truncate to terminal width
    if (( ${#result} > _TV_TERM_COLS ))
    then
        result="${result:0:$((_TV_TERM_COLS - 1))}"
    fi

    printf '%s%s%s' "$__BU_TV_DIM" "$result" "$__BU_TV_RESET"
}

# ═══════════════════════════════════════════════════════════════════════════
# Input handling
# ═══════════════════════════════════════════════════════════════════════════

# ```
# *Description*:
# Read a single keypress.  Handles multi-byte escape sequences.
#
# *Returns*:
# - stdout: Key name (e.g. "up", "down", "page_down", "/", "q")
# ```
__bu_tv_read_key()
{
    local key
    IFS= read -r -s -n 1 key

    if [[ "$key" != $'\e' ]]
    then
        if [[ "$key" == '' ]]
        then
            printf 'q'
            return
        fi
        if [[ "$key" == $'\x0c' ]]
        then
            printf 'ctrl_l'
            return
        fi
        printf '%s' "$key"
        return
    fi

    local seq
    IFS= read -r -s -n 1 -t 0.01 seq
    if [[ -z "$seq" ]]
    then
        printf 'escape'
        return
    fi

    if [[ "$seq" == '[' ]]
    then
        IFS= read -r -s -n 1 -t 0.01 seq
        case "$seq" in
            A) printf 'up' ;;
            B) printf 'down' ;;
            C) printf 'right' ;;
            D) printf 'left' ;;
            H) printf 'home' ;;
            F) printf 'end' ;;
            1) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && printf 'home'
               [[ "$seq" == ';' ]] && IFS= read -r -s -n 1 -t 0.01 seq ;;
            2) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && printf 'insert' ;;
            3) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && printf 'delete' ;;
            4) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && printf 'end' ;;
            5) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && printf 'page_up' ;;
            6) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && printf 'page_down' ;;
            7) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && printf 'home' ;;
            8) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && printf 'end' ;;
        esac
    elif [[ "$seq" == 'O' ]]
    then
        IFS= read -r -s -n 1 -t 0.01 seq
        case "$seq" in
            H) printf 'home' ;;
            F) printf 'end' ;;
        esac
    fi
}

# ```
# *Description*:
# Read a line of input (temporarily restores echo/canonical mode).
#
# *Params*:
# - `$1`: Prompt string (e.g. "/" or "?")
#
# *Returns*:
# - stdout: The user's input line
# ```
__bu_tv_read_line()
{
    local prompt=$1
    printf '%s' "$__BU_TV_CURSOR_SHOW"
    stty echo icanon 2>/dev/null || true
    printf '\e[%d;1H' "$_TV_TERM_ROWS"
    printf '\e[K%s' "$prompt"

    local input
    IFS= read -r input

    stty -echo -icanon 2>/dev/null || true
    printf '%s' "$__BU_TV_CURSOR_HIDE"
    printf '%s' "$input"
}

# ═══════════════════════════════════════════════════════════════════════════
# Actions
# ═══════════════════════════════════════════════════════════════════════════

__bu_tv_scroll_down()  { _TV_ROW_OFFSET=$((_TV_ROW_OFFSET + ${1:-1})); __bu_tv_clamp_offsets; }
__bu_tv_scroll_up()    { _TV_ROW_OFFSET=$((_TV_ROW_OFFSET - ${1:-1})); __bu_tv_clamp_offsets; }
__bu_tv_scroll_right() { _TV_COL_OFFSET=$((_TV_COL_OFFSET + ${1:-1})); __bu_tv_clamp_offsets; }
__bu_tv_scroll_left()  { _TV_COL_OFFSET=$((_TV_COL_OFFSET - ${1:-1})); __bu_tv_clamp_offsets; }
__bu_tv_go_top()       { _TV_ROW_OFFSET=0; }

__bu_tv_go_bottom()
{
    local -i visible=$((_TV_TERM_ROWS - 3))
    (( visible < 1 )) && visible=1
    _TV_ROW_OFFSET=$((_TV_NUM_ROWS - visible))
    (( _TV_ROW_OFFSET < 0 )) && _TV_ROW_OFFSET=0
}

__bu_tv_page_down()
{
    local -i visible=$((_TV_TERM_ROWS - 3))
    (( visible < 1 )) && visible=1
    __bu_tv_scroll_down $visible
}

__bu_tv_page_up()
{
    local -i visible=$((_TV_TERM_ROWS - 3))
    (( visible < 1 )) && visible=1
    __bu_tv_scroll_up $visible
}

__bu_tv_update_highlight_col()
{
    local -a vis_cols=()
    local col_idx
    for col_idx in $(__bu_tv_visible_cols)
    do
        vis_cols+=($col_idx)
    done
    if (( ${#vis_cols[@]} > 0 ))
    then
        _TV_HIGHLIGHT_COL=${vis_cols[0]}
    fi
}

# ── Sort ─────────────────────────────────────────────────────────────────

# ```
# *Description*:
# Sort rows by the given column key.  Toggles direction if already sorted
# by this column.
# ```
__bu_tv_sort_by_column()
{
    local col_key=$1
    [[ -z "$col_key" ]] && return

    if [[ "$_TV_SORT_COL" == "$col_key" ]]
    then
        if [[ "$_TV_SORT_DIR" == asc ]]
        then
            _TV_SORT_DIR=desc
        else
            _TV_SORT_DIR=asc
        fi
    else
        _TV_SORT_COL="$col_key"
        _TV_SORT_DIR=asc
    fi

    __bu_tv_apply_sort
}

# ```
# *Description*:
# Apply current sort to _TV_ROWS via jq, rebuild cache, reset view.
# ```
__bu_tv_apply_sort()
{
    [[ -z "$_TV_SORT_COL" ]] && return

    local jq_sort
    if [[ "$_TV_SORT_DIR" == desc ]]
    then
        jq_sort="sort_by(.[\"$_TV_SORT_COL\"]) | reverse"
    else
        jq_sort="sort_by(.[\"$_TV_SORT_COL\"])"
    fi

    local -a sorted=()
    local line
    while IFS= read -r line
    do
        sorted+=("$line")
    done < <(printf '%s\n' "${_TV_ROWS[@]}" | "$BU_OUT_JQ" -c "$jq_sort")

    _TV_ROWS=("${sorted[@]}")
    _TV_ROW_OFFSET=0
    __bu_tv_rebuild_cache
    __bu_tv_update_search_matches
}

# ── Search ───────────────────────────────────────────────────────────────

# ```
# *Description*:
# Update _TV_MATCHED_ROWS from the current search query.  Searches all
# columns case-insensitively using the cell cache (no jq forks).
# ```
__bu_tv_update_search_matches()
{
    _TV_MATCHED_ROWS=()
    _TV_MATCH_IDX=-1
    if [[ -z "$_TV_SEARCH_QUERY" ]]
    then
        return
    fi

    local lower_query=${_TV_SEARCH_QUERY,,}
    local -i i j
    for (( i = 0; i < _TV_NUM_ROWS; i++ ))
    do
        for (( j = 0; j < _TV_NUM_COLS; j++ ))
        do
            local cell
            cell=$(__bu_tv_get_cell $i $j)
            if [[ "${cell,,}" == *"$lower_query"* ]]
            then
                _TV_MATCHED_ROWS+=($i)
                break
            fi
        done
    done

    if (( ${#_TV_MATCHED_ROWS[@]} > 0 ))
    then
        _TV_MATCH_IDX=0
        _TV_ROW_OFFSET=${_TV_MATCHED_ROWS[0]}
        __bu_tv_clamp_offsets
    fi
}

__bu_tv_search_next()
{
    (( ${#_TV_MATCHED_ROWS[@]} == 0 )) && return
    _TV_MATCH_IDX=$((_TV_MATCH_IDX + 1))
    (( _TV_MATCH_IDX >= ${#_TV_MATCHED_ROWS[@]} )) && _TV_MATCH_IDX=0
    _TV_ROW_OFFSET=${_TV_MATCHED_ROWS[$_TV_MATCH_IDX]}
    __bu_tv_clamp_offsets
}

__bu_tv_search_prev()
{
    (( ${#_TV_MATCHED_ROWS[@]} == 0 )) && return
    _TV_MATCH_IDX=$((_TV_MATCH_IDX - 1))
    (( _TV_MATCH_IDX < 0 )) && _TV_MATCH_IDX=$((${#_TV_MATCHED_ROWS[@]} - 1))
    _TV_ROW_OFFSET=${_TV_MATCHED_ROWS[$_TV_MATCH_IDX]}
    __bu_tv_clamp_offsets
}

__bu_tv_search_start()
{
    local query
    query=$(__bu_tv_read_line "/")
    if [[ -z "$query" ]]
    then
        __bu_tv_render_frame
        return
    fi
    _TV_SEARCH_QUERY="$query"
    __bu_tv_update_search_matches
}

__bu_tv_search_start_reverse()
{
    local query
    query=$(__bu_tv_read_line "?")
    if [[ -z "$query" ]]
    then
        __bu_tv_render_frame
        return
    fi
    _TV_SEARCH_QUERY="$query"
    __bu_tv_update_search_matches
    if (( ${#_TV_MATCHED_ROWS[@]} > 0 ))
    then
        _TV_MATCH_IDX=$((${#_TV_MATCHED_ROWS[@]} - 1))
        _TV_ROW_OFFSET=${_TV_MATCHED_ROWS[$_TV_MATCH_IDX]}
        __bu_tv_clamp_offsets
    fi
}

__bu_tv_search_clear()
{
    _TV_SEARCH_QUERY=
    _TV_MATCHED_ROWS=()
    _TV_MATCH_IDX=-1
}

# ═══════════════════════════════════════════════════════════════════════════
# Main entry point
# ═══════════════════════════════════════════════════════════════════════════

# ```
# *Description*:
# Entry point for the interactive table viewer.
#
# *Params*:
# - `$1`: Column spec (comma-separated key:Label,...) — optional
# - `$2`: Color spec (key=color,... or "auto") — optional
#
# *Notes*:
# - Reads JSONL from stdin.
# - Blocks until the user presses q.
# ```
bu_tv_enter()
{
    local columns_spec=$1
    local colors_spec=$2

    # The viewer manages its own error handling; errexit would break the
    # event loop and cause spurious exits on false (( ... )) guards.
    set +e

    # ── Load and index data ───────────────────────────────────────────
    __bu_tv_read_stdin

    if (( _TV_NUM_ROWS == 0 ))
    then
        bu_log_info "bu tv: no records to display"
        return 0
    fi

    __bu_tv_extract_columns "$columns_spec" || return 1
    if (( _TV_NUM_COLS == 0 ))
    then
        bu_log_info "bu tv: no columns found"
        return 0
    fi

    __bu_tv_rebuild_cache
    __bu_tv_build_colors "$colors_spec" || return 1

    # ── After consuming piped stdin, switch to /dev/tty for keyboard ─
    if [[ -c /dev/tty ]]; then
        exec </dev/tty
    fi

    # ── Terminal setup ────────────────────────────────────────────────
    __bu_tv_terminal_setup
    __bu_tv_clamp_offsets

    # ── Event loop ────────────────────────────────────────────────────
    local key
    while true
    do
        __bu_tv_render_frame
        key=$(__bu_tv_read_key)

        case "$key" in
        q|Q)
            break ;;

        # Row navigation
        j|$'\x0a')       __bu_tv_scroll_down 1 ;;
        k)               __bu_tv_scroll_up 1 ;;
        down)            __bu_tv_scroll_down 1 ;;
        up)              __bu_tv_scroll_up 1 ;;

        # Column navigation
        h)               __bu_tv_scroll_left 1;  __bu_tv_update_highlight_col ;;
        l)               __bu_tv_scroll_right 1; __bu_tv_update_highlight_col ;;
        left)            __bu_tv_scroll_left 1;  __bu_tv_update_highlight_col ;;
        right)           __bu_tv_scroll_right 1; __bu_tv_update_highlight_col ;;

        # Page navigation
        $'\x20'|page_down) __bu_tv_page_down ;;
        b|page_up)         __bu_tv_page_up ;;

        # Jump to top/bottom
        g)               __bu_tv_go_top ;;
        G)               __bu_tv_go_bottom ;;

        # Half-page scroll (Ctrl-d / Ctrl-u)
        $'\x04')         __bu_tv_scroll_down $(((_TV_TERM_ROWS - 3) / 2)) ;;
        $'\x15')         __bu_tv_scroll_up   $(((_TV_TERM_ROWS - 3) / 2)) ;;

        # Search
        /)               __bu_tv_search_start ;;
        '?')             __bu_tv_search_start_reverse ;;
        n)               __bu_tv_search_next ;;
        N)               __bu_tv_search_prev ;;
        $'\e'|escape)    __bu_tv_search_clear ;;

        # Sort
        s)
            __bu_tv_update_highlight_col
            local sort_key=${_TV_COLUMNS[$_TV_HIGHLIGHT_COL]:-}
            [[ -n "$sort_key" ]] && __bu_tv_sort_by_column "$sort_key"
            ;;
        S)
            __bu_tv_update_highlight_col
            local sort_key=${_TV_COLUMNS[$_TV_HIGHLIGHT_COL]:-}
            if [[ -n "$sort_key" ]]
            then
                _TV_SORT_COL="$sort_key"
                _TV_SORT_DIR=desc
                __bu_tv_apply_sort
            fi
            ;;

        # Redraw on Ctrl-l
        ctrl_l)
            __bu_tv_update_dimensions
            __bu_tv_clamp_offsets
            ;;

        # Jump to first/last column
        home)   _TV_COL_OFFSET=0;                 __bu_tv_update_highlight_col ;;
        end)    _TV_COL_OFFSET=$((_TV_NUM_COLS - 1))
                __bu_tv_clamp_offsets
                __bu_tv_update_highlight_col ;;
        esac
    done

    __bu_tv_terminal_restore
}
