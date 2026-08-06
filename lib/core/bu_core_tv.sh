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
declare -g -a _TV_VIS_COLS=()       # Visible column indices, computed once per frame
declare -g    _TV_FC_TEXT=          # Out-param: formatted cell text (__bu_tv_format_cell)
declare -g -i _TV_FC_VIS_LEN=0      # Out-param: visible width of _TV_FC_TEXT (ANSI excluded)
declare -g    _TV_KEY=              # Out-param: last key read (__bu_tv_read_key)
declare -g    _TV_QUIT=false        # Event-loop exit flag

# Padding pools — slice with ${__BU_TV_SPACES:0:N} instead of per-cell append
# loops.  Grown by doubling (__bu_tv_ensure_pools) if a column exceeds the pool.
declare -g __BU_TV_SPACES=
declare -g __BU_TV_DASHES=
# 64 spaces, quadrupled to 256
__BU_TV_SPACES="                                                                "
__BU_TV_SPACES+=${__BU_TV_SPACES}${__BU_TV_SPACES}${__BU_TV_SPACES}
__BU_TV_DASHES=${__BU_TV_SPACES// /-}

# ```
# *Description*:
# Grow the space/dash padding pools (by doubling) until they hold at least
# N characters.
#
# *Params*:
# - `$1`: Required pool size
# ```
__bu_tv_ensure_pools()
{
    local -i need=$1
    while (( ${#__BU_TV_SPACES} < need ))
    do
        __BU_TV_SPACES+=$__BU_TV_SPACES
        __BU_TV_DASHES+=$__BU_TV_DASHES
    done
}

# ── Helpers ──────────────────────────────────────────────────────────────

# ```
# *Description*:
# Strip ANSI escape sequences from a string in place.  Handles both CSI
# sequences (ESC [ params letter — colors, bold, reverse) and charset
# selection sequences (ESC ( X / ESC ) X, e.g. the \e(B emitted by
# tput sgr0 as part of BU_TPUT_RESET).
#
# *Params*:
# - `$1`: Nameref to the variable to strip
# ```
__bu_tv_strip_ansi()
{
    local -n __bu_tv_strip_ref=$1
    local -r __bu_tv_ansi_re=$'\e'"(\\[[0-9;]*[a-zA-Z]|[()].)"
    while [[ $__bu_tv_strip_ref =~ $__bu_tv_ansi_re ]]
    do
        __bu_tv_strip_ref=${__bu_tv_strip_ref//"${BASH_REMATCH[0]}"/}
    done
}

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
            # JSONL values may embed ANSI (e.g. colored producers);
            # measure the visible width only.
            __bu_tv_strip_ansi cell_val
            if (( ${#cell_val} > wid )); then wid=${#cell_val}; fi
        done
        if (( wid < 4 )); then wid=4; fi
        if (( wid > max_width )); then wid=$max_width; fi
        _TV_COL_WIDTHS+=($wid)
    done
}

# ```
# *Description*:
# Highlight ALL occurrences of a query string within a text variable by
# wrapping them in reverse video.  Case-insensitive, pure bash (no forks).
# Replaces the old printf|sed pipeline which forked twice per cell.
#
# *Params*:
# - `$1`: Nameref to the text variable (modified in place)
# - `$2`: Query string (matched literally, case-insensitively)
# ```
__bu_tv_highlight_text()
{
    local -n __ht_ref=$1
    local query=$2
    if [[ -z "$query" || -z "$__ht_ref" ]]
    then
        return 0
    fi
    local lower_query=${query,,}
    local -i qlen=${#lower_query}
    local result= rest=$__ht_ref
    local lower_rest=${rest,,}
    while [[ $lower_rest == *"$lower_query"* ]]
    do
        # Index of the first match: %% strips the longest suffix starting
        # at the query, leaving the literal prefix.
        local prefix=${lower_rest%%"$lower_query"*}
        local -i idx=${#prefix}
        result+=${rest:0:idx}${__BU_TV_REVERSE}${rest:idx:qlen}${__BU_TV_REVERSE_OFF}
        rest=${rest:idx+qlen}
        lower_rest=${rest,,}
    done
    __ht_ref=$result$rest
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
# Install the viewer's full trap set.  Called at setup and again from the
# SIGCONT handler (on resume after a SIGSTOP stop).  The EXIT/INT/TERM path
# clears all traps via terminal_restore.
# ```
__bu_tv_install_traps()
{
    # Standard TUI practice: ignore SIGTTOU for the viewer's lifetime so a
    # stty/tcsetattr or tty write from a transiently-backgrounded state
    # proceeds instead of default-STOPping the whole pipeline.
    trap '' SIGTTOU
    trap '__bu_tv_terminal_restore; exit 0' SIGINT SIGTERM
    trap '__bu_tv_cleanup_exit' EXIT
    trap '__bu_tv_on_resize' SIGWINCH
    trap '__bu_tv_on_tstp' SIGTSTP
    trap '__bu_tv_on_cont' SIGCONT
}

# ```
# *Description*:
# Enter raw terminal mode: alternate screen, hide cursor, non-canonical
# input, install signal traps.
#
# *Returns*:
# - 1 without touching the terminal if our process group is not the tty's
#   foreground group (a loud failure instead of a silent SIGTTOU stop).
# ```
__bu_tv_terminal_setup()
{
    # Foreground guard: if our pgid is not the tty's foreground pgid, the
    # stty below would deliver SIGTTOU and the kernel would silently stop
    # the entire pipeline.  Refuse to start instead.
    local my_pgid tty_pgid
    my_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
    tty_pgid=$(ps -o tpgid= -p $$ 2>/dev/null | tr -d ' ')
    if [[ -n "$my_pgid" && -n "$tty_pgid" && "$my_pgid" != "$tty_pgid" ]]
    then
        bu_log_err "bu view-table: process group $my_pgid is not the terminal's foreground group ($tty_pgid)"
        bu_log_err "Run it in the foreground (e.g. '... | bu view-table' in a fresh shell)"
        return 1
    fi

    _TV_SAVED_STTY=$(stty -g 2>/dev/null) || _TV_SAVED_STTY=
    stty -echo -icanon 2>/dev/null || true

    printf '%s' "$__BU_TV_ALT_SCREEN_ON"
    printf '%s' "$__BU_TV_CURSOR_HIDE"
    printf '%s%s' "$__BU_TV_CURSOR_HOME" "$__BU_TV_CLEAR_SCREEN"

    __bu_tv_update_dimensions

    __bu_tv_install_traps
    return 0
}

# ```
# *Description*:
# Leave the TUI terminal state: show cursor, exit alternate screen, restore
# saved stty settings.  Does NOT clear traps — used by both the final
# restore and the SIGTSTP suspend path (which must keep SIGCONT armed).
# ```
__bu_tv_terminal_leave_tui()
{
    printf '%s' "$__BU_TV_CURSOR_SHOW"
    printf '%s' "$__BU_TV_ALT_SCREEN_OFF"

    if [[ -n "$_TV_SAVED_STTY" ]]
    then
        stty "$_TV_SAVED_STTY" 2>/dev/null || true
    fi
}

# ```
# *Description*:
# Restore terminal to its original state on exit: clear every trap the
# viewer installed (including TSTP/CONT/TTOU), then leave the TUI state.
# ```
__bu_tv_terminal_restore()
{
    trap - SIGINT SIGTERM SIGWINCH SIGTSTP SIGCONT SIGTTOU EXIT
    __bu_tv_terminal_leave_tui
}

# ```
# *Description*:
# SIGTSTP handler (Ctrl-Z): restore the terminal so the shell prompt is
# usable while stopped, then send SIGSTOP to unconditionally stop the process.
#
# We use SIGSTOP (not a re-raised SIGTSTP) because bash defers trap mutations
# for the currently-handled signal: inside the SIGTSTP handler, `trap -` does
# not take effect and the re-raised SIGTSTP stays blocked until the handler
# returns, at which point the old handler fires again — an infinite loop.
# SIGSTOP cannot be caught, blocked, or ignored, so it always stops the
# process immediately.  The CONT trap (still armed) handles the fg-side resume.
# ```
__bu_tv_on_tstp()
{
    __bu_tv_terminal_leave_tui
    kill -SIGSTOP $$
}

# ```
# *Description*:
# SIGCONT handler (fg): re-arm the full trap set, re-enter raw mode +
# alternate screen, recompute dimensions, clamp offsets, redraw.
# ```
__bu_tv_on_cont()
{
    __bu_tv_install_traps
    stty -echo -icanon 2>/dev/null || true
    printf '%s' "$__BU_TV_ALT_SCREEN_ON"
    printf '%s' "$__BU_TV_CURSOR_HIDE"
    __bu_tv_update_dimensions
    __bu_tv_clamp_offsets
    __bu_tv_render_frame
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
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Rendering
# ═══════════════════════════════════════════════════════════════════════════

# ```
# *Description*:
# Compute the column indices visible in the current viewport, once per frame.
#
# *Returns*:
# - `_TV_VIS_COLS`: Array of visible column indices
# ```
__bu_tv_compute_visible_cols()
{
    _TV_VIS_COLS=()
    local -i j used=0
    for (( j = _TV_COL_OFFSET; j < _TV_NUM_COLS; j++ ))
    do
        (( used + _TV_COL_WIDTHS[j] + 2 > _TV_TERM_COLS )) && break
        _TV_VIS_COLS+=($j)
        : $((used += _TV_COL_WIDTHS[j] + 2))
    done
    return 0
}

# ```
# *Description*:
# Build the formatted text and visible width for a single data cell.
# Pure bash, no forks: reads _TV_CELLS[] directly.
#
# *Params*:
# - `$1`: Row index
# - `$2`: Column index
#
# *Returns*:
# - `_TV_FC_TEXT`: Cell text with ANSI styling (color, search highlight)
# - `_TV_FC_VIS_LEN`: Visible width (ANSI excluded); equals the column
#   width when truncated.  Search highlighting does not change it.
# ```
__bu_tv_format_cell()
{
    local -i row_idx=$1 col_idx=$2
    local -i col_w=${_TV_COL_WIDTHS[$col_idx]}
    local key=${_TV_COLUMNS[$col_idx]}

    _TV_FC_TEXT=${_TV_CELLS[$((row_idx * _TV_NUM_COLS + col_idx))]:-}

    # Visible width — strip embedded ANSI only when present (cheap check)
    local -i raw_len
    if [[ $_TV_FC_TEXT == *$'\e'* ]]
    then
        local __vis=$_TV_FC_TEXT
        __bu_tv_strip_ansi __vis
        raw_len=${#__vis}
    else
        raw_len=${#_TV_FC_TEXT}
    fi

    # Truncate with ellipsis if needed
    if (( raw_len > col_w ))
    then
        _TV_FC_TEXT="${_TV_FC_TEXT:0:$((col_w - 1))}…"
        _TV_FC_VIS_LEN=$col_w
    else
        _TV_FC_VIS_LEN=$raw_len
    fi

    # Search highlighting (inserts ANSI only; visible length unchanged)
    if [[ -n "$_TV_SEARCH_QUERY" ]]
    then
        __bu_tv_highlight_text _TV_FC_TEXT "$_TV_SEARCH_QUERY"
    fi

    # Color prefix
    local color=${_TV_COLORS[$key]:-}
    if [[ -n "$color" ]]
    then
        _TV_FC_TEXT="${color}${_TV_FC_TEXT}${__BU_TV_RESET}"
    fi
}

# ```
# *Description*:
# Render a single table line (header, separator, or data row).
#
# *Params*:
# - `$1`: Row index (-1 = header, -2 = separator, >= 0 = data row)
# - `$2`: "true" if this row should be highlighted as the current search match
# - `$3`: Nameref to the output variable
#
# *Returns*:
# - `$3`: Formatted row string, right-trimmed
# ```
__bu_tv_render_line()
{
    local -i row_idx=$1
    local is_current_match=$2
    local -n __rl_out=$3
    __rl_out=
    local sep=
    local j
    for j in "${_TV_VIS_COLS[@]}"
    do
        local -i col_w=${_TV_COL_WIDTHS[$j]}
        (( col_w > ${#__BU_TV_SPACES} )) && __bu_tv_ensure_pools $col_w
        if (( row_idx == -1 ))
        then
            # Header (raw CSI bold — never tput-derived; sgr0 varies by TERM)
            local hdr=${_TV_HEADERS[$j]}
            local -i hdr_len=${#hdr}
            if (( hdr_len > col_w ))
            then
                hdr="${hdr:0:$((col_w - 1))}…"
                hdr_len=$((col_w - 1))
            fi
            __rl_out+="$sep${__BU_TV_ESC}[1m${hdr}${__BU_TV_ESC}[0m${__BU_TV_SPACES:0:col_w-hdr_len}"
        elif (( row_idx == -2 ))
        then
            # Separator
            __rl_out+="$sep${__BU_TV_DASHES:0:col_w}"
        else
            # Data row — cell text and visible width come from format_cell;
            # no ANSI re-stripping needed here.
            __bu_tv_format_cell "$row_idx" "$j"
            local cell=$_TV_FC_TEXT
            local padstr=
            local -i padw=$((col_w - _TV_FC_VIS_LEN))
            (( padw > 0 )) && padstr=${__BU_TV_SPACES:0:padw}
            if "$is_current_match" && (( _TV_MATCH_IDX >= 0 ))
            then
                __rl_out+="$sep${__BU_TV_REVERSE}${cell}${padstr}${__BU_TV_REVERSE_OFF}"
            else
                __rl_out+="$sep${cell}${padstr}"
            fi
        fi
        sep='  '
    done
    # Right-trim trailing spaces
    __rl_out=${__rl_out%"${__rl_out##*[! ]}"}
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

    __bu_tv_compute_visible_cols

    local frame= line=

    # Header (row 1)
    __bu_tv_render_line -1 false line
    printf -v frame '%s\e[1;1H%s\e[K' "$frame" "$line"

    # Separator (row 2)
    __bu_tv_render_line -2 false line
    printf -v frame '%s\e[2;1H%s\e[K' "$frame" "$line"

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
            __bu_tv_render_line "$row_idx" "$is_match" line
            printf -v frame '%s\e[%d;1H%s\e[K' "$frame" "$screen_row" "$line"
        fi
    done

    # Status line (bottom row) — absolute position, no trailing newline
    local status
    __bu_tv_render_status status
    printf -v frame '%s\e[%d;1H%s\e[K' "$frame" "$_TV_TERM_ROWS" "$status"

    printf '%s' "$frame"
}

# ```
# *Description*:
# Build the status line string.
#
# *Params*:
# - `$1`: Nameref to the output variable
# ```
__bu_tv_render_status()
{
    local -n __rs_out=$1
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

    __rs_out=${__BU_TV_DIM}${result}${__BU_TV_RESET}
}

# ═══════════════════════════════════════════════════════════════════════════
# Input handling
# ═══════════════════════════════════════════════════════════════════════════

# ```
# *Description*:
# Read a single keypress into _TV_KEY.  Handles multi-byte escape sequences.
#
# *Params*:
# - `$1` (optional): 1 = block until a key arrives (default);
#                    0 = non-blocking probe (returns 1 if no input queued)
#
# *Returns*:
# - `_TV_KEY`: Key name (e.g. "up", "down", "page_down", "/", "q").
#              EOF maps to "q" so the viewer exits cleanly on closed stdin.
# - Exit 1 only in probe mode when no input was available.
# ```
# ```
# *Description*:
# Read a single keypress into _TV_KEY.  Handles multi-byte escape sequences.
#
# *Params*:
# - `$1` (optional): 1 = block until a key arrives (default);
#                    0 = non-blocking probe (returns 1 if no input queued)
#
# *Returns*:
# - `_TV_KEY`: Key name (e.g. "up", "down", "page_down", "/", "q").
#   - real EOF (read rc=1)          -> "q" (quit)
#   - Enter (read rc=0, empty var)  -> $'\x0a' (read -n1 consumed the delimiter)
#   - trapped signal (read rc>128)  -> "none" (redraw-only no-op, NOT quit)
# - Exit 1 only in probe mode when no input was available.
# ```
__bu_tv_read_key()
{
    local -i blocking=${1:-1}
    local -i rc=0
    _TV_KEY=
    if (( blocking ))
    then
        IFS= read -r -s -n 1 _TV_KEY || rc=$?
    else
        # Probe with a hair of timeout so the byte (if any) is consumed
        IFS= read -r -s -n 1 -t 0.001 _TV_KEY || rc=$?
    fi

    if (( rc != 0 ))
    then
        if (( ! blocking ))
        then
            # Probe: nothing queued (timeout) or EOF — no key to dispatch
            return 1
        fi
        if (( rc > 128 ))
        then
            # A trapped signal (SIGWINCH, SIGCONT, ...) interrupted the
            # blocking read.  The handler already redrew; the event loop
            # treats "none" as redraw-only.
            _TV_KEY=none
            return 0
        fi
        # Real EOF
        _TV_KEY=q
        return 0
    fi

    if [[ -z "$_TV_KEY" ]]
    then
        # rc=0 with an empty var: read -n1 consumed the newline delimiter
        _TV_KEY=$'\x0a'
        return 0
    fi

    if [[ "$_TV_KEY" != $'\e' ]]
    then
        if [[ "$_TV_KEY" == $'\x0c' ]]
        then
            _TV_KEY=ctrl_l
        fi
        return 0
    fi

    local seq
    IFS= read -r -s -n 1 -t 0.01 seq
    if [[ -z "$seq" ]]
    then
        _TV_KEY=escape
        return 0
    fi

    if [[ "$seq" == '[' ]]
    then
        IFS= read -r -s -n 1 -t 0.01 seq
        case "$seq" in
            A) _TV_KEY=up ;;
            B) _TV_KEY=down ;;
            C) _TV_KEY=right ;;
            D) _TV_KEY=left ;;
            H) _TV_KEY=home ;;
            F) _TV_KEY=end ;;
            1) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && _TV_KEY=home
               [[ "$seq" == ';' ]] && IFS= read -r -s -n 1 -t 0.01 seq ;;
            2) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && _TV_KEY=insert ;;
            3) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && _TV_KEY=delete ;;
            4) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && _TV_KEY=end ;;
            5) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && _TV_KEY=page_up ;;
            6) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && _TV_KEY=page_down ;;
            7) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && _TV_KEY=home ;;
            8) IFS= read -r -s -n 1 -t 0.01 seq
               [[ "$seq" == '~' ]] && _TV_KEY=end ;;
        esac
    elif [[ "$seq" == 'O' ]]
    then
        IFS= read -r -s -n 1 -t 0.01 seq
        case "$seq" in
            H) _TV_KEY=home ;;
            F) _TV_KEY=end ;;
        esac
    fi
    return 0
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
    __bu_tv_compute_visible_cols
    if (( ${#_TV_VIS_COLS[@]} > 0 ))
    then
        _TV_HIGHLIGHT_COL=${_TV_VIS_COLS[0]}
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
        return 0
    fi

    local lower_query=${_TV_SEARCH_QUERY,,}
    local -i i j base
    for (( i = 0; i < _TV_NUM_ROWS; i++ ))
    do
        base=$((i * _TV_NUM_COLS))
        for (( j = 0; j < _TV_NUM_COLS; j++ ))
        do
            if [[ ${_TV_CELLS[base+j],,} == *"$lower_query"* ]]
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
    return 0
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

# ```
# *Description*:
# Dispatch one keypress (in _TV_KEY) to its action.  Sets _TV_QUIT=true on q.
# ```
__bu_tv_dispatch_key()
{
    case "$_TV_KEY" in
    q|Q)
        _TV_QUIT=true ;;

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
    __bu_tv_terminal_setup || return 1
    __bu_tv_clamp_offsets

    # ── Event loop ────────────────────────────────────────────────────
    # One render per drained input batch: after the first (blocking) key,
    # coalesce any already-queued keypresses and process them without
    # rendering, so a held key can't build a backlog of stale frames.
    _TV_QUIT=false
    while ! "$_TV_QUIT"
    do
        __bu_tv_render_frame
        __bu_tv_read_key 1
        __bu_tv_dispatch_key
        while ! "$_TV_QUIT" && __bu_tv_read_key 0
        do
            __bu_tv_dispatch_key
        done
    done

    __bu_tv_terminal_restore
}
