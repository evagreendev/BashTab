# The purpose of early init is so that we can make some things available to downstream repos
# to use in their pre-init callbacks. Most importantly, the builtin bu commands.
# This avoids some of the need to do double initialization, i.e.
# initialize BashTab fully just to have the bu builtin commands,
# then call the bu builtin commands inside a downstream repo activation script,
# then reinitialize again.
if false; then
source ./bu_core_base.sh
source ./bu_core_autocomplete.sh
fi
__bu_init_env_commands()
{
    # ── Try to load the compat cache ──
    local cache_valid=false
    local fingerprint
    if bu_cap_cache_fingerprint; then
        fingerprint=$BU_RET
        if bu_cap_cache_load "$fingerprint"; then
            cache_valid=true
        fi
    fi

    local dir
    local file
    local convert_file_to_subcommand
    local command
    for dir in "${!BU_COMMAND_SEARCH_DIRS[@]}"
    do
        bu_env_append_path "$dir"
        convert_file_to_subcommand=${BU_COMMAND_SEARCH_DIRS[$dir]}
        for file in $(find "$dir" -type f -printf "%P\n")
        do
            case "$file" in
            *.txt|README|README.*|*.md) 
                continue
                ;;
            __*)
                # 2 underscores in front can be used to hide scripts
                continue
                ;;
            esac

            local script_path=$dir/$file
            command=${file%.sh}
            if [[ -n "$convert_file_to_subcommand" ]]
            then
                if $convert_file_to_subcommand "$file"
                then
                    command=$BU_RET
                fi
            fi

            # If the script declares --is-compatible, run it to check.
            # Scripts without it are assumed compatible (backward compat).
            # Matches both case-style (--is-compatible)) and if-style (--is-compatible").
            if grep -qE -- '--is-compatible[)"]' "$script_path" 2>/dev/null; then
                if $cache_valid; then
                    # Cache hit — check if this command was marked unavailable
                    if [[ -n "${BU_COMMAND_UNAVAILABLE[$command]:-}" ]]; then
                        continue
                    fi
                else
                    # Cache miss — probe
                    local reason
                    if ! reason=$(bash "$script_path" --is-compatible 2>&1); then
                        BU_COMMAND_UNAVAILABLE[$command]=$reason
                        continue
                    fi
                fi
            fi

            BU_COMMANDS[$command]=$script_path
        done
    done

    # Save cache if we probed fresh
    if ! $cache_valid && [[ -n "$fingerprint" ]]; then
        bu_cap_cache_save "$fingerprint"
    fi
}

__bu_init_env_commands
# Get bu_impl.sh on PATH so that bu can be called
bu_env_append_path "$BU_LIB_BINSRC_DIR"
