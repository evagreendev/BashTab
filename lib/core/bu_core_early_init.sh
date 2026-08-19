# The purpose of early init is so that we can make some things available to downstream repos
# to use in their pre-init callbacks. Most importantly, the builtin bu commands.
# This avoids some of the need to do double initialization, i.e.
# initialize BashTab fully just to have the bu builtin commands,
# then call the bu builtin commands inside a downstream repo activation script,
# then reinitialize again.

# bash-ide source=./bu_core_base.sh
# bash-ide source=./bu_core_autocomplete.sh
# bash-ide source=./bu_core_cache.sh

# ```
# *Description*:
# Read an explicit `# Dispatch: <type>` declaration from a command script
# header (first 8 lines).  Returns `source` or `execute` in BU_RET, or
# empty when the script declares no dispatch intent.
#
# *Params*:
# - `$1`: Path to the command script
#
# *Returns*:
# - BU_RET: declared dispatch type, or empty
# ```
__bu_command_dispatch_decl()
{
    BU_RET=
    local -r file=$1
    [[ -f "$file" ]] || return 0
    BU_RET=$(awk '
        FNR > 8 { exit }
        /^#[[:space:]]*Dispatch:[[:space:]]*(source|execute)[[:space:]]*$/ {
            line = $0
            sub(/^#[[:space:]]*Dispatch:[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            exit
        }
    ' "$file" 2>/dev/null)
}

__bu_init_env_commands()
{
    # ── Determine whether --is-compatible probes can be skipped ──
    local compat_cache_valid=false
    local fingerprint

    if "$BU_COMMAND_CACHE_LOADED"; then
        # Command cache was loaded — BU_COMMAND_UNAVAILABLE is already
        # populated.  Use it to skip --is-compatible probes.
        compat_cache_valid=true
    elif "$BU_COMMAND_CACHE_ENABLED" && bu_cap_cache_fingerprint; then
        # Try the per-environment compat cache (only when caching is enabled)
        fingerprint=$BU_RET
        if bu_cap_cache_load "$fingerprint"; then
            compat_cache_valid=true
        fi
    fi

    local _scan_lazy=${BU_COMMAND_SCAN_LAZY:-false}

    local dir
    local file
    local convert_file_to_subcommand
    local command
    for dir in "${!BU_COMMAND_SEARCH_DIRS[@]}"
    do
        bu_env_append_path "$dir"

        # ── Lazy mode: defer the scan body, only do PATH appends ──
        if "$_scan_lazy"; then
            continue
        fi

        convert_file_to_subcommand=${BU_COMMAND_SEARCH_DIRS[$dir]}
        local find_opts=()
        if ! "${BU_COMMAND_SEARCH_DIR_RECURSIVE[$dir]:-true}"; then
            find_opts+=(-maxdepth 1)
        fi
        find_opts+=(-type f)

        # Per-directory ignore file: <dir>/.bashtabignore
        # One glob pattern per line; # comments and blank lines are ignored.
        local -a ignore_patterns=()
        if [[ -f "$dir/.bashtabignore" ]]; then
            local _line
            while IFS= read -r _line; do
                _line=${_line%%#*}               # strip # comments
                _line=${_line#"${_line%%[![:space:]]*}"}  # ltrim
                _line=${_line%"${_line##*[![:space:]]}"}  # rtrim
                [[ -n "$_line" ]] && ignore_patterns+=("$_line")
            done < "$dir/.bashtabignore"
        fi

        for file in $(find "$dir" "${find_opts[@]}" -printf "%P\n")
        do
            bu_dirname "$file"
            local file_dir=$BU_RET
            bu_basename "$file"
            local file_name=$BU_RET

            if [[ ! -e "$dir"/"$file_dir"/__bu_entrypoint_decl.sh ]]
            then
                bu_gen_substitute BU_DIR <"$BU_LIB_TEMPLATE_DIR"/bu_entrypoint_decl_template.sh >"$dir"/"$file_dir"/__bu_entrypoint_decl.sh
            fi

            # Builtin skip list: docs, dotfiles, internal helpers
            case "$file_name" in
            *.txt|README|README.*|*.md) 
                continue
                ;;
            __*)
                # 2 underscores in front can be used to hide scripts
                continue
                ;;
            .*)
                # Dotfiles (hidden files)
                continue
                ;;
            esac

            # Per-directory .bashtabignore patterns: match against
            # path-relative-to-dir ($file) or basename ($file_name)
            local _skip=false
            local _pat
            for _pat in "${ignore_patterns[@]}"; do
                if [[ "$file" == $_pat || "$file_name" == $_pat ]]; then
                    _skip=true
                    break
                fi
            done
            "$_skip" && continue

            local script_path=$dir/$file
            command=${file%.sh}
            if [[ -n "$convert_file_to_subcommand" ]]
            then
                # Converter callback return codes:
                #   0 — use BU_RET as the command name
                #   1 — keep the default name (file name without .sh)
                #   2 — REJECT: skip this file entirely, do not register
                # The || capture is errexit-safe: prevents set -e from
                # aborting when the converter returns non-zero.
                local convert_rc=0
                $convert_file_to_subcommand "$file" || convert_rc=$?
                case $convert_rc in
                0) command=$BU_RET ;;
                2) continue ;;
                # 1 or any other non-zero: keep default command name
                esac
            fi

            # If the script declares --is-compatible, run it to check.
            # Scripts without it are assumed compatible (backward compat).
            # Matches both case-style (--is-compatible)) and if-style (--is-compatible").
            if grep -qE -- '--is-compatible[)"]' "$script_path" 2>/dev/null; then
                if $compat_cache_valid; then
                    # Cache hit — check if this command was marked unavailable
                    if [[ -n "${BU_COMMAND_UNAVAILABLE[$command]:-}" ]]; then
                        BU_COMMAND_PROPERTIES[$command,unavailable_path]=$script_path
                        continue
                    fi
                else
                    # Cache miss — probe
                    local reason
                    if ! reason=$(bash "$script_path" --is-compatible 2>&1); then
                        BU_COMMAND_UNAVAILABLE[$command]=$reason
                        BU_COMMAND_PROPERTIES[$command,unavailable_path]=$script_path
                        continue
                    fi
                fi
            fi

            # Record an explicit # Dispatch: <type> declaration so dispatch
            # honors intent regardless of the file's exec bit.
            local dispatch_decl
            __bu_command_dispatch_decl "$script_path"
            dispatch_decl=$BU_RET
            if [[ -n "$dispatch_decl" ]]; then
                BU_COMMAND_PROPERTIES[$command,type]=$dispatch_decl
                # A shell-mutating script with the exec bit is an attractive
                # nuisance: invoked as ./cmd.sh or via PATH it runs as a child
                # process and silently no-ops its mutations.
                if [[ "$dispatch_decl" == source && -x "$script_path" ]]; then
                    bu_log_warn "Command[$command] declares '# Dispatch: source' but has the exec bit; invoking it as '$script_path' will silently no-op its shell mutations. Use 'chmod -x' to remove the exec bit."
                fi
            fi

            BU_COMMANDS[$command]=$script_path

            local _dir_module=${BU_COMMAND_SEARCH_DIR_MODULE[$dir]:-}
            if [[ -n "$_dir_module" ]]
            then
                BU_COMMAND_PROPERTIES[$command,module]=$_dir_module
            fi
        done
    done

    # Save compat cache if we probed fresh (only when caching is enabled
    # and the command cache wasn't loaded)
    if "$BU_COMMAND_CACHE_ENABLED" && ! "$BU_COMMAND_CACHE_LOADED" && ! $compat_cache_valid && [[ -n "$fingerprint" ]]; then
        bu_cap_cache_save "$fingerprint"
    fi

    if "$_scan_lazy"; then
        __BU_COMMAND_SCAN_PENDING=true
    fi
}

# ```
# *Description*:
# Run the deferred command-registry scan if BU_COMMAND_SCAN_LAZY deferred it.
# Called at the top of the CLI dispatcher and completion entry point so the
# first by-name dispatch or completion transparently completes initialization.
# Cheap no-op when the scan already ran.
# ```
bu_ensure_command_scan()
{
    if [[ "${__BU_COMMAND_SCAN_PENDING:-false}" != true ]]; then
        return 0
    fi
    __BU_COMMAND_SCAN_PENDING=false
    # Temporarily clear lazy mode so __bu_init_env_commands runs the scan
    local _saved=${BU_COMMAND_SCAN_LAZY:-}
    BU_COMMAND_SCAN_LAZY=false
    __bu_init_env_commands
    if [[ -n "$_saved" ]]; then
        BU_COMMAND_SCAN_LAZY=$_saved
    else
        unset BU_COMMAND_SCAN_LAZY
    fi
    # Register script-level completions from the freshly-scanned registry
    __bu_init_autocomplete
}

__bu_init_env_commands
# Get bu_impl.sh on PATH so that bu can be called
bu_env_append_path "$BU_LIB_BINSRC_DIR"
