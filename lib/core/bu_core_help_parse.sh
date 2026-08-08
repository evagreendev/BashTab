# bash-ide source=./bu_core_base.sh

# MARK: --help / man-page parsing for option descriptions
# Extracts option descriptions from a command's --help or man page, caching
# results so the fzf preview pane can show option descriptions for external
# command completions.
#
# Strategy registry: maps command name → parse strategy.
# Strategies:
#   gnu    – run --help, parse GNU-style "  -o, --option  DESC" lines
#   usage  – run --help, parse "usage: cmd [-o] [--option ARG]" synopsis
#            lines for bare option tokens (no descriptions available)
#   man    – run "man <cmd>", parse OPTIONS section (future)
#
# When a command has no registered strategy, strategies are tried in order:
# gnu, then usage as fallback.  The first strategy that yields results wins.
declare -A -g __BU_HELP_PARSE_STRATEGY=(
    [git]=usage
)

# Directory for cached parse results.  Derived from BU_CACHE_DIR at source
# time; callers can override.
declare -g __BU_HELP_PARSE_CACHE_DIR="${BU_CACHE_DIR}/help-parse"
bu_mkdir "$__BU_HELP_PARSE_CACHE_DIR"

# Global associative array populated by strategy functions.  Declared here
# so that all strategies (which may be called before __bu_help_parse_get
# runs its declare) write to an associative array, not an indexed one.
declare -A -g __BU_HELP_PARSE_CACHE_MAP=()

# ```
# *Description*:
# Register a parse strategy for a command.  Modules and preinit scripts
# should call this to declare how a particular command's help should be
# parsed.
#
# *Params*:
# - `$1`: Command name (e.g. "git", "docker")
# - `$2`: Strategy: gnu, usage, or man
#
# *Examples*:
# ```bash
# bu_register_help_strategy git usage
# bu_register_help_strategy find man
# ```
# ```
bu_register_help_strategy()
{
    local -r cmd=$1
    local -r strategy=$2
    case "$strategy" in
    gnu|usage|man) ;;
    *)
        bu_log_err "Unknown help parse strategy[$strategy]. Expected: gnu, usage, man"
        return 1
        ;;
    esac
    __BU_HELP_PARSE_STRATEGY[$cmd]=$strategy
}

# ```
# *Description*:
# Normalize a command name into a cache key (path → basename, slashes → dashes).
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
    key=${key##*/}
    key=${key//\//-}
    printf '%s' "$key"
}

# ═══════════════════════════════════════════════════════════════════════
# Strategy: gnu — parse "  -o, --option  DESC" lines from --help
# ═══════════════════════════════════════════════════════════════════════

__bu_help_parse_gnu()
{
    local -r cmd=$1
    local help_text

    if ! help_text=$("$cmd" --help 2>/dev/null) || [[ -z "$help_text" ]]
    then
        return 1
    fi

    local -A parsed=()
    local current_opt=
    local current_desc=
    local in_options_section=false
    local saw_options_header=false

    while IFS= read -r line
    do
        # Detect OPTIONS section header
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

        "$saw_options_header" && ! "$in_options_section" && continue

        local opt_tokens=()
        local desc_rest=

        # GNU style: -o, --option[=VAL]  DESC  or  --option[=VAL]  DESC
        if [[ "$line" =~ ^[[:space:]]+(-[a-zA-Z0-9?],?[[:space:]]*)?(--?[a-zA-Z0-9][-a-zA-Z0-9]*)([=][[:space:]]*[A-Za-z0-9_-]*)?[[:space:]]{2,}(.*) ]]
        then
            local short_opt=${BASH_REMATCH[1]}
            short_opt=${short_opt//,/}
            short_opt=${short_opt## }
            short_opt=${short_opt%% }
            local long_opt=${BASH_REMATCH[2]}
            desc_rest=${BASH_REMATCH[4]}

            [[ -n "$short_opt" ]] && opt_tokens+=("$short_opt")
            opt_tokens+=("$long_opt")
        elif [[ "$line" =~ ^[[:space:]]+(-[a-zA-Z0-9?])[[:space:]]+[A-Z][A-Z_]*[[:space:]]{2,}(.*) ]]
        then
            # BSD style: -o  ARG  DESC
            opt_tokens+=("${BASH_REMATCH[1]}")
            desc_rest=${BASH_REMATCH[2]}
        elif [[ "$line" =~ ^[[:space:]]+(--?[a-zA-Z0-9][-a-zA-Z0-9]*)[[:space:]]{2,}(.*) ]]
        then
            # Simple: --option  DESC or -o  DESC
            opt_tokens+=("${BASH_REMATCH[1]}")
            desc_rest=${BASH_REMATCH[2]}
        fi

        if ((${#opt_tokens[@]}))
        then
            if [[ -n "$current_opt" ]]
            then
                for _o in $current_opt; do
                    parsed[$_o]=${current_desc#"${current_desc%%[![:space:]]*}"}
                done
            fi
            current_opt="${opt_tokens[*]}"
            current_desc=$desc_rest
        elif [[ -n "$current_opt" ]] && [[ "$line" =~ ^[[:space:]]{4,}([^ ].*) ]]
        then
            current_desc+=" ${BASH_REMATCH[1]}"
        else
            if [[ -n "$current_opt" ]]
            then
                for _o in $current_opt; do
                    parsed[$_o]=${current_desc#"${current_desc%%[![:space:]]*}"}
                done
                current_opt=
                current_desc=
            fi
        fi
    done <<< "$help_text"

    if [[ -n "$current_opt" ]]
    then
        for _o in $current_opt; do
            parsed[$_o]=${current_desc#"${current_desc%%[![:space:]]*}"}
        done
    fi

    ((${#parsed[@]})) || return 1

    local _opt
    for _opt in "${!parsed[@]}"; do
        __BU_HELP_PARSE_CACHE_MAP[$_opt]=${parsed[$_opt]}
    done
    return 0
}

# ═══════════════════════════════════════════════════════════════════════
# Strategy: usage — parse "usage: cmd [-o] [--option ARG]" lines
# Extracts option tokens from bracket-delimited synopsis lines.
# No descriptions are available; options get an empty-string value.
# ═══════════════════════════════════════════════════════════════════════

__bu_help_parse_usage()
{
    local -r cmd=$1
    local help_text

    if ! help_text=$("$cmd" --help 2>/dev/null) || [[ -z "$help_text" ]]
    then
        return 1
    fi

    local -A parsed=()
    local usage_lines=()

    # Collect all usage/synopsis lines
    while IFS= read -r line
    do
        # Match "usage:" or "Usage:" prefix
        if [[ "$line" =~ ^[[:space:]]*[Uu]sage: ]]
        then
            usage_lines+=("$line")
        elif ((${#usage_lines[@]})) && [[ "$line" =~ ^[[:space:]]{6,}[^A-Za-z] ]]
        then
            # Continuation line: indented continuation of the usage block
            usage_lines+=("$line")
        else
            # Stop collecting once we hit non-continuation after usage block
            ((${#usage_lines[@]})) && break
        fi
    done <<< "$help_text"

    ((${#usage_lines[@]})) || return 1

    # Join all usage lines, strip "usage: cmd" prefix, then extract option
    # tokens from bracket-delimited groups like [-o], [--option ARG], etc.
    local joined="${usage_lines[*]}"
    # Strip "usage: " prefix and the command name
    joined=${joined#*[Uu]sage: }
    joined=${joined#"$cmd"}   # strip the command name itself
    joined=${joined## }       # trim leading space

    # Extract tokens that look like options from bracket-enclosed groups.
    # We process the joined text character by character to handle nested
    # brackets and alternation (|).
    local token=
    local -a tokens=()
    local in_bracket=false
    local in_angle=false
    local i ch

    for (( i = 0; i < ${#joined}; i++ ))
    do
        ch=${joined:i:1}
        case "$ch" in
        '[')
            in_bracket=true
            token=
            ;;
        ']')
            in_bracket=false
            # Process the accumulated token inside brackets
            if [[ -n "$token" ]]
            then
                # Split on | for alternation: [-v | --version]
                local -a alts=()
                local _alt _ifs=$IFS
                IFS='|'
                for _t in $token; do
                    _t=${_t## }
                    _t=${_t%% }
                    [[ -n "$_t" ]] && alts+=("$_t")
                done
                IFS=$_ifs
                for _alt in "${alts[@]}"
                do
                    # Only keep tokens starting with - (skip ARG placeholders
                    # like <path>, <name>, etc.)
                    if [[ "$_alt" == -* ]]
                    then
                        # Strip trailing =VALUE from --option=VALUE
                        _alt=${_alt%%=*}
                        # Strip [...] suffix from --option[=VALUE]
                        _alt=${_alt%%[*}
                        # Trim leading/trailing whitespace
                        _alt=${_alt## }
                        _alt=${_alt%% }
                        parsed[$_alt]=
                    fi
                done
            fi
            ;;
        '<')
            in_angle=true
            ;;
        '>')
            in_angle=false
            ;;
        *)
            "$in_bracket" && ! "$in_angle" && token+=$ch
            ;;
        esac
    done

    ((${#parsed[@]})) || return 1

    local _opt
    for _opt in "${!parsed[@]}"; do
        __BU_HELP_PARSE_CACHE_MAP[$_opt]=
    done
    return 0
}

# ═══════════════════════════════════════════════════════════════════════
# Strategy: man — parse "man <cmd>" OPTIONS section (stub / future)
# ═══════════════════════════════════════════════════════════════════════

__bu_help_parse_man()
{
    local -r cmd=$1
    # Future: run "man <cmd> 2>/dev/null | col -bx" and parse the OPTIONS
    # section using man-page heuristics.
    return 1
}

# ═══════════════════════════════════════════════════════════════════════
# Dispatcher + caching layer
# ═══════════════════════════════════════════════════════════════════════

# ```
# *Description*:
# Resolve the effective strategy for a command.  Checks the registry first,
# then falls back to a trial order: gnu, then usage.
#
# *Params*:
# - `$1`: Command name
#
# *Returns*:
# - stdout: Strategy name (gnu, usage, or man), or empty if nothing works
# ```
__bu_help_parse_resolve_strategy()
{
    local -r cmd=$1

    # Explicit registration
    if [[ -n "${__BU_HELP_PARSE_STRATEGY[$cmd]:-}" ]]
    then
        printf '%s' "${__BU_HELP_PARSE_STRATEGY[$cmd]}"
        return 0
    fi

    # Auto-detect: default to gnu
    printf 'gnu'
}

# ```
# *Description*:
# Compute the cache hash for a command + strategy combination.  We hash the
# strategy name together with the command's help output so that switching
# strategies for a command invalidates the old cache.
#
# *Params*:
# - `$1`: Command to run
# - `$2`: Strategy name (gnu, usage, man)
# - nameref `$3`: Output variable for the hash (empty on failure)
# ```
__bu_help_parse_hash()
{
    local -r cmd=$1
    local -r strategy=$2
    local -n _out=$3
    _out=

    local help_text
    case "$strategy" in
    gnu|usage)
        help_text=$("$cmd" --help 2>/dev/null) || return 1
        ;;
    man)
        help_text=$(man "$cmd" 2>/dev/null | col -bx 2>/dev/null) || return 1
        ;;
    *) return 1 ;;
    esac

    [[ -z "$help_text" ]] && return 1
    _out=$(printf '%s\n%s' "$strategy" "$help_text" | sha256sum 2>/dev/null | cut -d' ' -f1)
    [[ -n "$_out" ]]
}

# ```
# *Description*:
# Run the appropriate strategy for a command and populate the global
# associative array __BU_HELP_PARSE_CACHE_MAP.
#
# *Params*:
# - `$1`: Command to run (e.g. "grep", "git")
#
# *Returns*:
# - 0 on success, 1 if no strategy produced results
# - Populates __BU_HELP_PARSE_CACHE_MAP assoc: option token → description
# ```
__bu_help_parse_run()
{
    local -r cmd=$1
    local -r cache_key=$(__bu_help_parse_cache_key "$cmd")
    local -r strategy=$(__bu_help_parse_resolve_strategy "$cmd")
    local -r cache_file="$__BU_HELP_PARSE_CACHE_DIR/${cache_key}.${strategy}"

    # ── Cache hit check ──
    local help_hash
    if __bu_help_parse_hash "$cmd" "$strategy" help_hash && [[ -n "$help_hash" ]]
    then
        local cached_hash
        if cached_hash=$(head -1 "$cache_file" 2>/dev/null) && [[ "$cached_hash" == "$help_hash" ]]
        then
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

    # ── Cache miss: run the strategy ──
    local -a strategies_to_try=("$strategy")
    # If no explicit registration and gnu is the resolved strategy,
    # also try usage as fallback
    if [[ -z "${__BU_HELP_PARSE_STRATEGY[$cmd]:-}" && "$strategy" == gnu ]]
    then
        strategies_to_try+=(usage)
    fi

    local _strat _ok=false
    for _strat in "${strategies_to_try[@]}"
    do
        case "$_strat" in
        gnu)   __bu_help_parse_gnu   "$cmd" && _ok=true ;;
        usage) __bu_help_parse_usage "$cmd" && _ok=true ;;
        man)   __bu_help_parse_man   "$cmd" && _ok=true ;;
        esac
        "$_ok" && break
    done

    "$_ok" || return 1

    # ── Write cache (use the strategy that actually succeeded) ──
    local _cache_file="$__BU_HELP_PARSE_CACHE_DIR/${cache_key}.${_strat}"
    __bu_help_parse_hash "$cmd" "$_strat" help_hash || return 1
    if ((${#__BU_HELP_PARSE_CACHE_MAP[@]}))
    then
        {
            printf '%s\n' "$help_hash"
            local _opt
            for _opt in "${!__BU_HELP_PARSE_CACHE_MAP[@]}"
            do
                printf '%s\t%s\n' "$_opt" "${__BU_HELP_PARSE_CACHE_MAP[$_opt]}"
            done | sort
        } > "$_cache_file"
    fi

    return 0
}

# ```
# *Description*:
# Get option descriptions for a command.  Runs --help / man on first call
# and caches the result; subsequent calls return instantly from cache.
#
# *Params*:
# - `$1`: Command name or path (e.g. "grep", "/usr/bin/tar", "git")
# - `$2`: Name of an associative array to populate (nameref)
#
# *Returns*:
# - 0 on success (array may be empty if no options found)
# - 1 if no strategy produced results or command not found
# - Populates the nameref array: option token → description
# ```
__bu_help_parse_get()
{
    local -r cmd=$1
    local -n _out=$2
    _out=()

    command -v "$cmd" &>/dev/null || return 1

    __BU_HELP_PARSE_CACHE_MAP=()
    __bu_help_parse_run "$cmd" || return 1

    local _opt
    for _opt in "${!__BU_HELP_PARSE_CACHE_MAP[@]}"
    do
        _out[$_opt]=${__BU_HELP_PARSE_CACHE_MAP[$_opt]}
    done
    return 0
}

# ```
# *Description*:
# Enrich BU_COMPREPLY_METADATA with option descriptions for external
# commands.  Called during fzf autocomplete binding after completions
# have been generated.
#
# *Params*:
# - `$1`: Command name being completed (e.g. "grep")
# - nameref `$2`: COMPREPLY array of completion candidates
# - nameref `$3`: BU_COMPREPLY_METADATA array to enrich
#
# *Returns*:
# - Sets BU_RET to "true" if preview should be shown, "false" otherwise
# ```
__bu_help_enrich_preview()
{
    local -r cmd=$1
    local -n _comps=$2
    local -n _meta=$3
    BU_RET=false

    # Only process external commands (not BashTab built-ins)
    [[ -n "${BU_COMMANDS[$cmd]:-}" ]] && return 0

    # Only process if there are completions that look like options
    local has_options=false
    local _c
    for _c in "${_comps[@]}"
    do
        [[ "$_c" == -* ]] && { has_options=true; break; }
    done
    "$has_options" || return 0

    # Get parsed help
    declare -A _help_opts=()
    __bu_help_parse_get "$cmd" _help_opts 2>/dev/null || return 0
    ((${#_help_opts[@]})) || return 0

    # Build a lookup-friendly key set: space-padded so we can use [[ $set == *" key "* ]]
    local _key_set=" "
    local _k
    for _k in "${!_help_opts[@]}"; do
        _key_set+="$_k "
    done

    local _i _desc _clean _prefix _found
    local _enriched=false
    for ((_i = 0; _i < ${#_comps[@]}; _i++))
    do
        _c=${_comps[$_i]}
        [[ "$_c" != -* ]] && continue

        _desc=
        _found=false

        # Exact match
        if [[ "$_key_set" == *" $_c "* ]]
        then
            _desc=${_help_opts[$_c]}
            _found=true
        # Strip trailing = for --option=ARG
        elif [[ "$_c" == *=* ]]
        then
            local _stripped=${_c%%=*}
            if [[ "$_key_set" == *" $_stripped "* ]]
            then
                _desc=${_help_opts[$_stripped]}
                _found=true
            fi
        fi

        # Prefix shortening: -verbose → -v
        if ! "$_found"
        then
            _prefix=$_c
            while [[ ${#_prefix} -gt 1 ]]
            do
                if [[ "$_key_set" == *" $_prefix "* ]]
                then
                    _desc=${_help_opts[$_prefix]}
                    _found=true
                    break
                fi
                _prefix=${_prefix::-1}
            done
        fi

        if "$_found"
        then
            _clean=${_desc#"${_desc%%[![:space:]]*}"}
            if [[ -n "$_clean" ]]
            then
                if ((${#_meta[_i]} == 0))
                then
                    _meta[_i]="${BU_TPUT_GREY}${_clean}${BU_TPUT_RESET}"
                else
                    _meta[_i]+=" | ${BU_TPUT_GREY}${_clean}${BU_TPUT_RESET}"
                fi
            fi
            _enriched=true
        fi
    done

    "$_enriched" && BU_RET=true
}
