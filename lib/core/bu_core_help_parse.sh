# bash-ide source=./bu_core_base.sh

# MARK: --help output parsing for option descriptions
# Extracts option descriptions from a command's --help output and caches
# them so the fzf preview pane can show man-page-quality descriptions for
# external command options.

# Directory for cached --help parse results.  Derived from BU_CACHE_DIR at
# source time; callers can override.
declare -g __BU_HELP_PARSE_CACHE_DIR="${BU_CACHE_DIR}/help-parse"
bu_mkdir "$__BU_HELP_PARSE_CACHE_DIR"

# ```
# *Description*:
# Normalize a command name into a cache key (slashes → dashes).
#
# *Params*:
# - `$1`: Command name (e.g. "git", "docker-compose", "/usr/bin/tar")
#
# *Returns*:
# - stdout: Cache-safe key
# ```
__bu_help_parse_cache_key()
{
    local key=$1
    key=${key##*/}                 # strip path
    key=${key//\//-}               # remaining slashes → dashes
    printf '%s' "$key"
}

# ```
# *Description*:
# Run a command's --help and extract option descriptions into the global
# associative array __BU_HELP_PARSE_CACHE_MAP.  Uses a simple line-oriented
# parser that handles the most common --help styles:
#
#   -o, --option[=ARG]   Description text here...
#   -o  ARG              Description text here... (BSD style)
#   --option=ARG          Description text here...
#
# Continuation lines (indented text after a description) are appended.
#
# *Params*:
# - `$1`: Command to run (e.g. "grep", "find")
#
# *Returns*:
# - 0 on success, 1 if --help failed or produced no parseable output
# - Populates __BU_HELP_PARSE_CACHE_MAP assoc: option token → description
#
# *Notes*:
# - Only processes the OPTIONS section when detectable; otherwise processes
#   the entire output.
# - Options without descriptions get an empty-string entry.
# - Single-letter short options (-o) are mapped; long options (--option)
#   are mapped; both point to the same description when on the same line.
# ```
__bu_help_parse_run()
{
    local -r cmd=$1
    local -r cache_key=$(__bu_help_parse_cache_key "$cmd")
    local -r cache_file="$__BU_HELP_PARSE_CACHE_DIR/$cache_key"

    # ── Cache: check if we already have results for this command ──
    # We key the cache on the command path + --help output hash so that
    # package upgrades (which change help output) invalidate automatically.
    local help_hash
    if help_hash=$("$cmd" --help 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1) && [[ -n "$help_hash" ]]
    then
        local cached_hash
        if cached_hash=$(head -1 "$cache_file" 2>/dev/null) && [[ "$cached_hash" == "$help_hash" ]]
        then
            # Cache hit — parse the stored entries
            local _line _opt _desc
            while IFS= read -r _line
            do
                [[ "$_line" == "$help_hash" ]] && continue
                _opt=${_line%%$'\t'*}
                _desc=${_line#*$'\t'}
                __BU_HELP_PARSE_CACHE_MAP[$_opt]=$_desc
            done < "$cache_file"
            return 0
        fi
    else
        return 1
    fi

    # ── Cache miss: run --help and parse ──
    local help_text
    if ! help_text=$("$cmd" --help 2>/dev/null) || [[ -z "$help_text" ]]
    then
        return 1
    fi

    # Parse option lines from the help text.
    # Strategy: look for lines that start with whitespace + option pattern.
    # We track the "current option" so continuation lines (indented text
    # after an option line with no new option token) are appended.
    local -A parsed=()
    local current_opt=
    local current_desc=
    local in_options_section=false
    local saw_options_header=false

    while IFS= read -r line
    do
        # Detect OPTIONS section header (common patterns)
        if [[ "$line" =~ ^[[:space:]]*OPTIONS?$ || "$line" =~ ^[A-Z][A-Z[:space:]]+OPTIONS?$ ]]
        then
            saw_options_header=true
            in_options_section=true
            continue
        fi

        # End of OPTIONS section: a new all-caps section header
        if "$in_options_section" && [[ "$line" =~ ^[[:space:]]*[A-Z][A-Z[:space:]]{2,}$ ]] && [[ ! "$line" =~ OPTIONS? ]]
        then
            in_options_section=false
            continue
        fi

        # If we saw an OPTIONS header but aren't in it anymore, skip
        # (allows parsing full output when no OPTIONS section exists)
        if "$saw_options_header" && ! "$in_options_section"
        then
            continue
        fi

        # Try to match an option pattern at the start of the line
        # Pattern 1: -o, --option[=ARG]  DESC  (GNU style, most common)
        # Pattern 2: --option[=ARG]  DESC
        # Pattern 3: -o  ARG  DESC  (BSD style, short option with argument)
        local opt_tokens=()
        local desc_rest=

        # GNU style: -o, --option[=VAL]  DESC  or  --option[=VAL]  DESC
        if [[ "$line" =~ ^[[:space:]]+(-[a-zA-Z0-9?],?[[:space:]]*)?(--?[a-zA-Z0-9][-a-zA-Z0-9]*)([=][[:space:]]*[A-Za-z0-9_-]*)?[[:space:]]{2,}(.*) ]]
        then
            # BASH_REMATCH: [0]=full, [1]=short opt incl comma/space, [2]=long/full opt, [3]==ARG, [4]=desc
            local short_opt=${BASH_REMATCH[1]}          # e.g. "-E, " or "-o "
            short_opt=${short_opt//,/}                  # strip comma: "-E, " -> "-E "
            short_opt=${short_opt## }                   # trim leading space
            short_opt=${short_opt%% }                   # trim trailing space: "-E " -> "-E"
            local long_opt=${BASH_REMATCH[2]}           # e.g. "--extended-regexp" or "-E"
            desc_rest=${BASH_REMATCH[4]}                # rest after option

            [[ -n "$short_opt" ]] && opt_tokens+=("$short_opt")
            opt_tokens+=("$long_opt")
        elif [[ "$line" =~ ^[[:space:]]+(-[a-zA-Z0-9?])[[:space:]]+[A-Z][A-Z_]*[[:space:]]{2,}(.*) ]]
        then
            # BSD style: -o  ARG  DESC
            local short_opt=${BASH_REMATCH[1]}
            desc_rest=${BASH_REMATCH[2]}
            opt_tokens+=("$short_opt")
        elif [[ "$line" =~ ^[[:space:]]+(--?[a-zA-Z0-9][-a-zA-Z0-9]*)[[:space:]]{2,}(.*) ]]
        then
            # Simple: --option  DESC or -o  DESC
            local opt=${BASH_REMATCH[1]}
            desc_rest=${BASH_REMATCH[2]}
            opt_tokens+=("$opt")
        fi

        if ((${#opt_tokens[@]}))
        then
            # Flush previous option
            if [[ -n "$current_opt" ]]
            then
                for _o in $current_opt
                do
                    parsed[$_o]=${current_desc#"${current_desc%%[![:space:]]*}"}
                done
            fi

            current_opt="${opt_tokens[*]}"
            current_desc=$desc_rest
        elif [[ -n "$current_opt" ]] && [[ "$line" =~ ^[[:space:]]{4,}([^ ].*) ]]
        then
            # Continuation line: indented text after an option description
            local cont=${BASH_REMATCH[1]}
            current_desc+=" $cont"
        else
            # Flush previous option on non-option, non-continuation line
            if [[ -n "$current_opt" ]]
            then
                for _o in $current_opt
                do
                    parsed[$_o]=${current_desc#"${current_desc%%[![:space:]]*}"}
                done
                current_opt=
                current_desc=
            fi
        fi
    done <<< "$help_text"

    # Flush last option
    if [[ -n "$current_opt" ]]
    then
        for _o in $current_opt
        do
            parsed[$_o]=${current_desc#"${current_desc%%[![:space:]]*}"}
        done
    fi

    # ── Write cache ──
    if ((${#parsed[@]}))
    then
        {
            printf '%s\n' "$help_hash"
            local _opt
            for _opt in "${!parsed[@]}"
            do
                printf '%s\t%s\n' "$_opt" "${parsed[$_opt]}"
            done | sort
        } > "$cache_file"
    fi

    # ── Populate caller's array ──
    local _opt
    for _opt in "${!parsed[@]}"
    do
        __BU_HELP_PARSE_CACHE_MAP[$_opt]=${parsed[$_opt]}
    done

    return 0
}

# ```
# *Description*:
# Get option descriptions for a command.  Runs --help on first call and
# caches the result; subsequent calls return instantly from cache.
#
# *Params*:
# - `$1`: Command name or path (e.g. "grep", "/usr/bin/tar")
# - `$2`: Name of an associative array to populate (nameref)
#
# *Returns*:
# - 0 on success (array may be empty if no options found)
# - 1 if --help failed or command not found
# - Populates the nameref array: option token → description
#
# *Examples*:
# ```bash
# declare -A opts
# __bu_help_parse_get grep opts
# echo "${opts[-v]}"   # "invert the sense of matching..."
# echo "${opts[--ignore-case]}"  # "ignore case distinctions..."
# ```
# ```
__bu_help_parse_get()
{
    local -r cmd=$1
    local -n _out=$2

    # Reset caller's array
    _out=()

    # Check if command exists
    if ! command -v "$cmd" &>/dev/null
    then
        return 1
    fi

    # Use temp global to collect results from __bu_help_parse_run
    declare -A -g __BU_HELP_PARSE_CACHE_MAP=()
    __bu_help_parse_run "$cmd" || return 1

    # Copy to caller's array
    local _opt
    for _opt in "${!__BU_HELP_PARSE_CACHE_MAP[@]}"
    do
        _out[$_opt]=${__BU_HELP_PARSE_CACHE_MAP[$_opt]}
    done

    return 0
}

# ```
# *Description*:
# Enrich BU_COMPREPLY_METADATA with option descriptions from --help output
# for external commands.  Called during fzf autocomplete binding after
# completions have been generated.
#
# *Params*:
# - `$1`: Command name being completed (e.g. "grep")
# - nameref `$2`: COMPREPLY array of completion candidates
# - nameref `$3`: BU_COMPREPLY_METADATA array to enrich
#
# *Returns*:
# - Sets BU_RET to "true" if preview should be shown, "false" otherwise
#
# *Notes*:
# - Only triggers when candidates look like options (start with -).
# - Enriches metadata in-place; preserves existing metadata entries.
# ```
__bu_help_enrich_preview()
{
    local -r cmd=$1
    local -n _comps=$2
    local -n _meta=$3
    BU_RET=false

    # Quick bail-out: only process external commands (not in BU_COMMANDS)
    [[ -n "${BU_COMMANDS[$cmd]:-}" ]] && return 0

    # Only process if there are completions that look like options
    local has_options=false
    local _c
    for _c in "${_comps[@]}"
    do
        if [[ "$_c" == -* ]]
        then
            has_options=true
            break
        fi
    done
    "$has_options" || return 0

    # Get parsed help
    declare -A _help_opts=()
    __bu_help_parse_get "$cmd" _help_opts 2>/dev/null || return 0
    ((${#_help_opts[@]})) || return 0

    local _i _opt _desc _clean
    local _enriched=false
    for ((_i = 0; _i < ${#_comps[@]}; _i++))
    do
        _c=${_comps[$_i]}
        [[ "$_c" != -* ]] && continue

        # Try exact match first, then try stripping trailing = for --option=ARG
        _desc=${_help_opts[$_c]:-}
        if [[ -z "$_desc" && "$_c" == *=* ]]
        then
            _desc=${_help_opts[${_c%%=*}]:-}
        fi
        # Try matching the shortest prefix that's a known option token
        # (handles -v from -verbose when only latter is in help)
        if [[ -z "$_desc" ]]
        then
            local _prefix=$_c
            while [[ ${#_prefix} -gt 1 ]]
            do
                _desc=${_help_opts[$_prefix]:-}
                [[ -n "$_desc" ]] && break
                _prefix=${_prefix::-1}
            done
        fi

        if [[ -n "$_desc" ]]
        then
            # Trim to a reasonable preview width (~60 chars for the pane)
            _clean=${_desc#"${_desc%%[![:space:]]*}"}  # ltrim
            if ((${#_meta[_i]} == 0))
            then
                _meta[_i]="${BU_TPUT_GREY}${_clean}${BU_TPUT_RESET}"
            else
                _meta[_i]+=" | ${BU_TPUT_GREY}${_clean}${BU_TPUT_RESET}"
            fi
            _enriched=true
        fi
    done

    "$_enriched" && BU_RET=true
}
