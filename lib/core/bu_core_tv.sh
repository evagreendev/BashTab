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
# Raw CSI only — never tput-derived: sgr0 is \e(B\e[m under xterm, \e[m\017
# under screen and empty under dumb, so frames would depend on TERM.
declare -g -r __BU_TV_RESET="${__BU_TV_ESC}[0m"
declare -g -r __BU_TV_BOLD="${__BU_TV_ESC}[1m"

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
declare -g -a _TV_SORT_PERM=()      # Last sort: new row index → old row index
declare -g    _TV_SEARCH_QUERY=     # Current search string
declare -g -a _TV_MATCHED_ROWS=()   # Indices of rows matching _TV_SEARCH_QUERY
declare -g -i _TV_MATCH_IDX=-1      # Current position in _TV_MATCHED_ROWS
declare -g -i _TV_TERM_ROWS=24
declare -g -i _TV_TERM_COLS=80
declare -g -i _TV_HIGHLIGHT_COL=0   # Leftmost visible column index (for sort hint)
declare -g    _TV_SAVED_STTY=       # Saved stty settings for cleanup
declare -g -a _TV_VIS_COLS=()       # Visible column indices, computed once per frame
declare -g    _TV_SIDEBAR=true      # Show the column sidebar (toggled with c)
declare -g -i _TV_TABLE_COLS=80     # Screen columns left for the table (__bu_tv_update_layout)
declare -g -i _TV_SIDEBAR_W=0       # Sidebar width incl. border, 0 = hidden
declare -g -i _TV_SIDEBAR_NAME_W=0  # Column-name width inside the sidebar
declare -g    _TV_FC_TEXT=          # Out-param: formatted cell text (__bu_tv_format_cell)
declare -g -i _TV_FC_VIS_LEN=0      # Out-param: visible width of _TV_FC_TEXT (ANSI excluded)
declare -g    _TV_KEY=              # Out-param: last key read (__bu_tv_read_key)
declare -g    _TV_QUIT=false        # Event-loop exit flag
# Signal flags: the traps only set these; __bu_tv_process_signals does the
# work from the event loop (see __bu_tv_install_traps for why)
declare -g    _TV_RESIZE_PENDING=false   # SIGWINCH
declare -g    _TV_SUSPEND_PENDING=false  # SIGTSTP (Ctrl-Z)
declare -g    _TV_RESUME_PENDING=false   # SIGCONT (fg)
# Blocking key reads wake this often (seconds) so a deferred WINCH trap runs
declare -g -r __BU_TV_KEY_POLL=0.1

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
# Rebuild the cell cache and compute column widths in a single jq pass.
#
# Each cell is escaped individually (`[.] | @tsv`: tab, newline, CR and
# backslash become two-character escapes) and a literal U+0001 becomes the
# six characters `\u0001`, so U+0001 can delimit cells.  jq emits two lines:
# the per-column maximum visible width (ANSI stripped, escaped text
# measured), then every cell of every row joined by U+0001 plus a trailing
# sentinel.  U+0001 is non-whitespace IFS, so `read -a` keeps interior
# empty cells; the sentinel protects a trailing empty one.
#
# *Params*:
# - None.  Reads _TV_ROWS[], _TV_COLUMNS[], _TV_NUM_ROWS, _TV_NUM_COLS.
#
# *Returns*:
# - Sets _TV_CELLS[] and _TV_COL_WIDTHS[].
# - 1 with both cleared if the parsed cell count is not rows x cols (a
#   shifted table must never be rendered).
# ```
__bu_tv_rebuild_cache()
{
    _TV_CELLS=()
    _TV_COL_WIDTHS=()
    if (( _TV_NUM_ROWS == 0 || _TV_NUM_COLS == 0 ))
    then
        return 0
    fi

    # ── Build jq arg list and expression ──────────────────────────────
    local -a jq_args=()
    local jq_keys= sep=
    local -i j
    for (( j = 0; j < _TV_NUM_COLS; j++ ))
    do
        jq_args+=('--arg' "c$j" "${_TV_COLUMNS[$j]}")
        jq_keys+="$sep.[\$c$j]"
        sep=,
    done

    # `// ""` would blank `false` too; only null is empty
    local jq_expr
    printf -v jq_expr '%s' \
        'map([' "$jq_keys" ']' \
        ' | map(if . == null then "" else tostring end | [.] | @tsv' \
        ' | gsub("\u0001"; "\\u0001"))) as $rows' \
        ' | ([range(' "$_TV_NUM_COLS" ') as $j | [$rows[][$j]' \
        ' | gsub("\u001b\\[[0-9;]*[A-Za-z]|\u001b[()]."; "") | length]' \
        ' | max] | map(tostring) | join(" ")),' \
        ' ([$rows[][]] + ["."] | join("\u0001"))'

    local out
    out=$(printf '%s\n' "${_TV_ROWS[@]}" | "$BU_OUT_JQ" -r -s "${jq_args[@]}" "$jq_expr")

    # One here-string, not ${out%%$'\n'*}: that expansion is quadratic in
    # the output size
    local -a widths=()
    {
        read -r -a widths
        IFS=$'\x01' read -r -a _TV_CELLS
    } <<<"$out"
    # Drop the sentinel
    (( ${#_TV_CELLS[@]} )) && unset '_TV_CELLS[-1]'

    local -i expected=$((_TV_NUM_ROWS * _TV_NUM_COLS))
    if (( ${#_TV_CELLS[@]} != expected || ${#widths[@]} != _TV_NUM_COLS ))
    then
        bu_log_err "bu view-table: parsed ${#_TV_CELLS[@]} cells and ${#widths[@]} widths, expected $expected cells ($_TV_NUM_ROWS rows x $_TV_NUM_COLS cols) and $_TV_NUM_COLS widths"
        _TV_CELLS=()
        _TV_COL_WIDTHS=()
        return 1
    fi

    # ── Widths: max of header and content, clamped to [4, 40] ────────
    local -i wid max_width=40
    for (( j = 0; j < _TV_NUM_COLS; j++ ))
    do
        wid=${widths[$j]}
        if (( ${#_TV_HEADERS[$j]} > wid )); then wid=${#_TV_HEADERS[$j]}; fi
        if (( wid < 4 )); then wid=4; fi
        if (( wid > max_width )); then wid=$max_width; fi
        _TV_COL_WIDTHS+=($wid)
    done
    return 0
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
# Install the viewer's full trap set.  Called at setup and again on resume
# after a stop.  terminal_restore clears all of them.
#
# Every trap only sets a flag; __bu_tv_process_signals does the work from
# the event loop.  The key reader blocks in short `read -t` slices, and
# bash runs a pending trap inside that read: when the slice's timer expires
# while the trap is still running, bash abandons the trap midway (e.g.
# during a $(stty ...) fork, which is slow under load).  A single
# assignment leaves nothing to abandon.
# ```
__bu_tv_install_traps()
{
    # Standard TUI practice: ignore SIGTTOU for the viewer's lifetime so a
    # stty/tcsetattr or tty write from a transiently-backgrounded state
    # proceeds instead of default-STOPping the whole pipeline.
    trap '' SIGTTOU
    trap '_TV_QUIT=true' SIGINT SIGTERM
    trap '__bu_tv_cleanup_exit' EXIT
    trap '_TV_RESIZE_PENDING=true' SIGWINCH
    trap '_TV_SUSPEND_PENDING=true' SIGTSTP
    trap '_TV_RESUME_PENDING=true' SIGCONT
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
# Act on the flags the traps set.  Called from the event loop before each
# render, outside any trap.  Each flag is cleared before its work so a
# signal arriving meanwhile is handled on the next pass.
#
# - Suspend (Ctrl-Z): restore the terminal so the shell prompt is usable
#   while stopped, then SIGSTOP ourselves (uncatchable, so it always stops).
#   Execution continues here after fg, which also counts as a resume.
# - Resume (fg, or SIGCONT after an external stop): re-arm the traps,
#   re-enter raw mode + alternate screen, and re-read the size.
# - Resize: re-read the size and clamp offsets.
# ```
__bu_tv_process_signals()
{
    if "$_TV_SUSPEND_PENDING"
    then
        _TV_SUSPEND_PENDING=false
        __bu_tv_terminal_leave_tui
        kill -SIGSTOP $$
        _TV_RESUME_PENDING=true
    fi
    if "$_TV_RESUME_PENDING"
    then
        _TV_RESUME_PENDING=false
        __bu_tv_install_traps
        stty -echo -icanon 2>/dev/null || true
        printf '%s' "$__BU_TV_ALT_SCREEN_ON"
        printf '%s' "$__BU_TV_CURSOR_HIDE"
        _TV_RESIZE_PENDING=true
    fi
    if "$_TV_RESIZE_PENDING"
    then
        _TV_RESIZE_PENDING=false
        __bu_tv_update_dimensions
        __bu_tv_clamp_offsets
    fi
    return 0
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
#
# Asks the tty itself (stty size).  Not tput: inside $(...) with stderr
# discarded, tput sees no terminal on stdout or stderr and silently reports
# the terminfo default (80x24 for xterm) with exit status 0.  COLUMNS/LINES
# are unexported shell variables, so the cmdlet process rarely has them.
# ```
__bu_tv_update_dimensions()
{
    _TV_TERM_COLS=80
    _TV_TERM_ROWS=24
    [[ -n "${COLUMNS:-}" ]] && _TV_TERM_COLS=$COLUMNS
    [[ -n "${LINES:-}" ]] && _TV_TERM_ROWS=$LINES
    # 2>/dev/null first so a failed /dev/tty open is silenced too
    local size= rows= cols=
    size=$(stty size 2>/dev/null </dev/tty) || size=
    # No `read` here: if this ever runs inside a trap again, a nested read
    # builtin clears the interrupted `read -t` timer in __bu_tv_read_key,
    # which then blocks until the next key
    rows=${size%% *}
    cols=${size##* }
    [[ "$rows" =~ ^[0-9]+$ ]] && _TV_TERM_ROWS=$rows
    [[ "$cols" =~ ^[0-9]+$ ]] && _TV_TERM_COLS=$cols
    if (( _TV_TERM_COLS < 20 )); then _TV_TERM_COLS=80; fi
    if (( _TV_TERM_ROWS < 10 )); then _TV_TERM_ROWS=24; fi
}

# ```
# *Description*:
# Split the screen width between the table and the column sidebar.  The
# sidebar is as wide as the longest column label (capped) plus border,
# cursor marker and sort arrow, and is hidden when the table would be left
# with fewer than __BU_TV_SIDEBAR_MIN_TABLE columns.
#
# *Returns*:
# - Sets _TV_TABLE_COLS, _TV_SIDEBAR_W (0 = hidden) and _TV_SIDEBAR_NAME_W.
# ```
declare -g -r -i __BU_TV_SIDEBAR_MAX_NAME=20
# 40 = widest column (see __bu_tv_rebuild_cache) + its 2-space gap
declare -g -r -i __BU_TV_SIDEBAR_MIN_TABLE=42
__bu_tv_update_layout()
{
    _TV_TABLE_COLS=$_TV_TERM_COLS
    _TV_SIDEBAR_W=0
    _TV_SIDEBAR_NAME_W=0
    if ! "$_TV_SIDEBAR" || (( _TV_NUM_COLS == 0 ))
    then
        return 0
    fi

    # Wide enough for the "Columns" title: marker + name + " ↑" >= 7
    local -i name_w=4 j
    for (( j = 0; j < _TV_NUM_COLS; j++ ))
    do
        (( ${#_TV_HEADERS[j]} > name_w )) && name_w=${#_TV_HEADERS[j]}
    done
    (( name_w > __BU_TV_SIDEBAR_MAX_NAME )) && name_w=$__BU_TV_SIDEBAR_MAX_NAME

    # "│ " + marker + name + " ↑"
    local -i width=$((2 + 1 + name_w + 2))
    (( _TV_TERM_COLS - width < __BU_TV_SIDEBAR_MIN_TABLE )) && return 0
    _TV_SIDEBAR_NAME_W=$name_w
    _TV_SIDEBAR_W=$width
    _TV_TABLE_COLS=$((_TV_TERM_COLS - width))
    return 0
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

    __bu_tv_update_layout

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
            (( used > _TV_TABLE_COLS )) && break
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
    __bu_tv_update_layout
    _TV_VIS_COLS=()
    local -i j used=0
    for (( j = _TV_COL_OFFSET; j < _TV_NUM_COLS; j++ ))
    do
        (( used + _TV_COL_WIDTHS[j] + 2 > _TV_TABLE_COLS )) && break
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
                # The ellipsis occupies the last cell: no padding left
                hdr="${hdr:0:$((col_w - 1))}…"
                hdr_len=$col_w
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
# Append the column sidebar to a frame: a "Columns" title and separator on
# screen rows 1-2, then one entry per column on the data rows.  Columns in
# the viewport are drawn in reverse video (in their --colors color), the
# rest dimmed; ▸ marks the leftmost visible column (the one s/S sort) and
# ↑/↓ the sorted column.  When the list is taller than the data rows it
# scrolls to keep the viewport's columns on screen, with "↑ N more" /
# "↓ N more" rows standing in for the hidden ends.
#
# *Params*:
# - `$1`: Nameref to the frame variable (appended to)
# - `$2`: Number of data rows
# ```
__bu_tv_render_sidebar()
{
    local -n __sb_frame=$1
    local -i avail=$2
    local -i col=$((_TV_TABLE_COLS + 1))
    local -i name_w=$_TV_SIDEBAR_NAME_W
    local -i inner_w=$((_TV_SIDEBAR_W - 2))
    (( inner_w > ${#__BU_TV_SPACES} )) && __bu_tv_ensure_pools $inner_w

    printf -v __sb_frame '%s\e[1;%dH│ %s%s%s\e[K' "$__sb_frame" "$col" \
        "$__BU_TV_BOLD" "Columns" "$__BU_TV_RESET"
    printf -v __sb_frame '%s\e[2;%dH│ %s\e[K' "$__sb_frame" "$col" \
        "${__BU_TV_DASHES:0:inner_w}"

    local -i first_vis=-1 last_vis=-1
    if (( ${#_TV_VIS_COLS[@]} ))
    then
        first_vis=${_TV_VIS_COLS[0]}
        last_vis=${_TV_VIS_COLS[-1]}
    fi

    # Window [start, start + cap) of entries; the rest of avail is taken
    # by the overflow indicator rows
    local -i start=0 cap=$_TV_NUM_COLS
    if (( _TV_NUM_COLS > avail ))
    then
        cap=$((avail - 2))
        start=$((first_vis - 1))
        (( start > _TV_NUM_COLS - cap )) && start=$((_TV_NUM_COLS - cap))
        (( start < 0 )) && start=0
        # Reclaim an indicator row the window doesn't need
        if (( start == 0 ))
        then
            cap=$((cap + 1))
        elif (( start + cap == _TV_NUM_COLS ))
        then
            start=$((start - 1))
            cap=$((cap + 1))
        fi
    fi
    local -i end=$((start + cap))

    local -i i j=$start screen_row
    local entry name marker suffix style
    local -i name_len
    for (( i = 0; i < avail; i++ ))
    do
        screen_row=$((i + 3))
        if (( i == 0 && start > 0 ))
        then
            entry="${__BU_TV_DIM}↑ $start more${__BU_TV_RESET}"
        elif (( j >= end ))
        then
            if (( j < _TV_NUM_COLS ))
            then
                entry="${__BU_TV_DIM}↓ $((_TV_NUM_COLS - j)) more${__BU_TV_RESET}"
                j=$_TV_NUM_COLS
            else
                entry=
            fi
        else
            name=${_TV_HEADERS[j]}
            name_len=${#name}
            if (( name_len > name_w ))
            then
                name="${name:0:name_w-1}…"
                name_len=$name_w
            fi
            marker=' '
            (( j == first_vis )) && marker='▸'
            suffix='  '
            if [[ "${_TV_COLUMNS[j]}" == "$_TV_SORT_COL" ]]
            then
                suffix=' ↑'
                [[ "$_TV_SORT_DIR" == desc ]] && suffix=' ↓'
            fi
            if (( j >= first_vis && j <= last_vis && first_vis >= 0 ))
            then
                style=${_TV_COLORS[${_TV_COLUMNS[j]}]:-}$__BU_TV_REVERSE
            else
                style=$__BU_TV_DIM
            fi
            entry="${style}${marker}${name}${__BU_TV_SPACES:0:name_w-name_len}${suffix}${__BU_TV_RESET}"
            j=$((j + 1))
        fi
        printf -v __sb_frame '%s\e[%d;%dH│ %s\e[K' "$__sb_frame" "$screen_row" "$col" "$entry"
    done
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
    #   right edge     = column sidebar on rows 1..N-1, unless hidden
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

    # Sidebar — drawn after the table so each row's \e[K ran first
    if (( _TV_SIDEBAR_W > 0 ))
    then
        __bu_tv_render_sidebar frame "$data_rows"
    fi

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

    # Row position (TERM_ROWS - 3 data rows, as in render_frame)
    local -i data_rows=$((_TV_TERM_ROWS - 3))
    (( data_rows < 1 )) && data_rows=1
    local -i last_visible=$((_TV_ROW_OFFSET + data_rows - 1))
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
    parts+=("q:quit /:search s:sort n:next c:columns")

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
# Succeed if a trap has set a flag the event loop must act on.
# ```
__bu_tv_signal_pending()
{
    "$_TV_QUIT" || "$_TV_RESIZE_PENDING" || "$_TV_SUSPEND_PENDING" || "$_TV_RESUME_PENDING"
}

# ```
# *Description*:
# Read a single keypress into _TV_KEY.  Handles multi-byte escape sequences.
#
# Blocking mode reads in __BU_TV_KEY_POLL slices rather than one indefinite
# read: bash restarts a read interrupted by SIGWINCH and defers its trap
# until a byte arrives, so a resize would otherwise not redraw until the
# next keypress.  A slice that ends with no signal flag set just reads
# again, so an idle viewer never renders.
#
# *Params*:
# - `$1` (optional): 1 = block until a key arrives (default);
#                    0 = non-blocking probe (returns 1 if no input queued)
#
# *Returns*:
# - `_TV_KEY`: Key name (e.g. "up", "down", "page_down", "/", "q").
#   - real EOF (read rc=1)          -> "q" (quit)
#   - Enter (read rc=0, empty var)  -> $'\x0a' (read -n1 consumed the delimiter)
#   - a trap set a signal flag or _TV_QUIT (read rc>128) -> "none"
#     (no-op; the event loop processes the flags, NOT quit by itself)
# - Exit 1 only in probe mode when no input was available.
# ```
__bu_tv_read_key()
{
    local -i blocking=${1:-1}
    local -i rc=0
    _TV_KEY=
    if (( blocking ))
    then
        while :
        do
            rc=0
            IFS= read -r -s -n 1 -t "$__BU_TV_KEY_POLL" _TV_KEY || rc=$?
            # rc>128: the slice timed out or a trapped signal interrupted it
            (( rc <= 128 )) && break
            __bu_tv_signal_pending && break
        done
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
            # A trap set a flag; the event loop processes it and redraws
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
# by this column, unless a direction is given.  The previous sort state is
# kept if the sort fails.
#
# *Params*:
# - `$1`: Column key
# - `$2` (optional): Force direction ("asc" or "desc")
# ```
__bu_tv_sort_by_column()
{
    local col_key=$1
    local force_dir=${2:-}
    [[ -z "$col_key" ]] && return 0

    local -r prev_col=$_TV_SORT_COL prev_dir=$_TV_SORT_DIR
    if [[ -n "$force_dir" ]]
    then
        _TV_SORT_DIR=$force_dir
    elif [[ "$_TV_SORT_COL" == "$col_key" && "$_TV_SORT_DIR" == asc ]]
    then
        _TV_SORT_DIR=desc
    else
        _TV_SORT_DIR=asc
    fi
    _TV_SORT_COL=$col_key

    if ! __bu_tv_apply_sort
    then
        _TV_SORT_COL=$prev_col
        _TV_SORT_DIR=$prev_dir
        return 1
    fi
    return 0
}

# ```
# *Description*:
# Apply current sort to _TV_ROWS via jq, rebuild cache, reset view.
# Sorting raw values (not cell strings) orders numbers numerically and null
# first.
#
# *Returns*:
# - `_TV_SORT_PERM`: New-to-old row index permutation (a cursor can follow
#   its record through the sort)
# - 1 with rows, cells and widths untouched if jq's output is not one
#   permutation line plus one line per row, or the cache rebuild fails.
# ```
__bu_tv_apply_sort()
{
    [[ -z "$_TV_SORT_COL" ]] && return 0

    local jq_expr='to_entries | sort_by(.value[$k])'
    [[ "$_TV_SORT_DIR" == desc ]] && jq_expr+=' | reverse'
    jq_expr+=' | (map(.key) | @tsv), (.[].value | tojson)'

    local -a sorted=()
    mapfile -t sorted < <(printf '%s\n' "${_TV_ROWS[@]}" \
        | "$BU_OUT_JQ" -r -s --arg k "$_TV_SORT_COL" "$jq_expr")
    if (( ${#sorted[@]} != _TV_NUM_ROWS + 1 ))
    then
        bu_log_err "bu view-table: sort by $_TV_SORT_COL produced ${#sorted[@]} lines, expected $((_TV_NUM_ROWS + 1)); rows left unsorted"
        return 1
    fi

    local -a prev_rows=("${_TV_ROWS[@]}")
    local -a prev_cells=("${_TV_CELLS[@]}")
    local -a prev_widths=("${_TV_COL_WIDTHS[@]}")
    _TV_ROWS=("${sorted[@]:1}")
    if ! __bu_tv_rebuild_cache
    then
        _TV_ROWS=("${prev_rows[@]}")
        _TV_CELLS=("${prev_cells[@]}")
        _TV_COL_WIDTHS=("${prev_widths[@]}")
        return 1
    fi
    IFS=$'\t' read -r -a _TV_SORT_PERM <<<"${sorted[0]}"
    _TV_ROW_OFFSET=0
    __bu_tv_update_search_matches
    return 0
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
        [[ -n "$sort_key" ]] && __bu_tv_sort_by_column "$sort_key" desc
        ;;

    # Toggle the column sidebar; the table width changes, so re-clamp
    c)
        if "$_TV_SIDEBAR"; then _TV_SIDEBAR=false; else _TV_SIDEBAR=true; fi
        __bu_tv_clamp_offsets
        __bu_tv_update_highlight_col
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
# Make bash count characters, not bytes.  Under a non-UTF-8 locale (e.g. LANG
# unset) ${#var}, substring slicing and read -n 1 work on bytes while the jq
# width pass counts codepoints, so any non-ASCII cell (or the status line's
# │) misaligns padding and truncation.  Process-local: the cmdlet runs in its
# own process.  LC_ALL must be cleared or it overrides LC_CTYPE.
# ```
__bu_tv_ensure_utf8_ctype()
{
    local -r loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
    case "${loc,,}" in
    *utf-8*|*utf8*)
        ;;
    *)
        unset LC_ALL
        export LC_CTYPE=C.UTF-8
        ;;
    esac
    return 0
}

# ```
# *Description*:
# Entry point for the interactive table viewer.
#
# *Params*:
# - `$1`: Column spec (comma-separated key:Label,...) — optional
# - `$2`: Color spec (key=color,... or "auto") — optional
# - `$3`: "false" to start with the column sidebar hidden — optional
#
# *Notes*:
# - Reads JSONL from stdin.
# - Blocks until the user presses q.
# ```
bu_tv_enter()
{
    local columns_spec=$1
    local colors_spec=$2
    _TV_SIDEBAR=${3:-true}

    # The viewer manages its own error handling; errexit would break the
    # event loop and cause spurious exits on false (( ... )) guards.
    set +e

    # Reset before the traps exist; a Ctrl-C during setup then still quits
    _TV_QUIT=false
    _TV_RESIZE_PENDING=false
    _TV_SUSPEND_PENDING=false
    _TV_RESUME_PENDING=false

    __bu_tv_ensure_utf8_ctype

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

    # A failed rebuild means the table would render shifted: don't start
    __bu_tv_rebuild_cache || return 1
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
    while ! "$_TV_QUIT"
    do
        __bu_tv_process_signals
        "$_TV_QUIT" && break
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
