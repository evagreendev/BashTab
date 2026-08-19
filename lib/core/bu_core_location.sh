# MARK: Named location registry
# PowerShell-flavored named directory targets ("goto shortcuts").
#
# A location is a name → target, where the target is either a lazily-expanded
# path expression (`--path '$MY_PROJECT_DIR/build'`, single-quoted by the
# caller) or a resolver function (`--resolver FN`, the escape hatch for
# computed/validated targets).  Entries are registered by core code, module
# preinits, and the user-local file (see bu_location_source_local_file).
#
# The repo registry (bu_core_repo.sh) layers on top: a repo IS a location
# plus git identity, stored in the same property table.

# These three arrays are re-initialized every time the entrypoint sources
# this file (bu_core_location.sh is intentionally sourced WITHOUT --__bu-once
# so re-activation starts from a clean slate before preinits and the local
# file re-register everything).
declare -A -g BU_LOCATION_REGISTRY=()      # name -> kind (dir|file|multi)
declare -A -g BU_LOCATION_PROPERTIES=()    # [name,path] [name,resolver] [name,description]
                                           # [name,tags] [name,on_enter] [name,source]
                                           # [name,repo_*] (see bu_core_repo.sh)
declare -A -g BU_LOCATION_ALIASES=()       # alias -> canonical name/key

# ```
# *Description*:
# First BASH_SOURCE frame OUTSIDE the location/repo registry core files.
# Used to record provenance ([name,source]) so a delegating wrapper (e.g.
# bu_repo_register) records the actual registrant (module preinit, local file).
#
# *Returns*:
# - BU_RET: source file path
# ```
__bu_location_provenance()
{
    local i file base
    for (( i = 0; i < ${#BASH_SOURCE[@]}; i++ ))
    do
        file=${BASH_SOURCE[$i]}
        base=${file##*/}
        [[ "$base" == bu_core_location.sh || "$base" == bu_core_repo.sh ]] && continue
        BU_RET=("$file")
        return 0
    done
    BU_RET=("${BASH_SOURCE[0]}")
    return 0
}

# ```
# *Description*:
# True when `tag` appears in the comma-separated tags CSV.
# ```
__bu_location_tag_match()
{
    local tags_csv=$1
    local tag=$2
    local ifs=$IFS t
    IFS=','
    for t in $tags_csv
    do
        [[ "$t" == "$tag" ]] && { IFS=$ifs; return 0; }
    done
    IFS=$ifs
    return 1
}

# ```
# *Description*:
# Reject path expressions that could become code execution at resolve time.
# A path typo must never run a command.  Plain $VAR / ${VAR} expansion is
# allowed; command substitution ($(...) and backticks) and shell metachars
# are not.
#
# *Returns*:
# - 0 if safe, 1 if the expression contains a forbidden sequence
# ```
__bu_location_validate_path_expr()
{
    local expr=$1
    if [[ "$expr" == *'$('* || "$expr" == *'`'* || "$expr" == *';'* \
       || "$expr" == *'&'* || "$expr" == *'|'* || "$expr" == *'<'* \
       || "$expr" == *'>'* || "$expr" == *$'\n'* ]]
    then
        return 1
    fi
    return 0
}

# ```
# *Description*:
# Expand a stored path expression at resolve time.  The expansion is
# double-quoted so a value containing spaces stays ONE path.  A leading
# `~`/`~/` is converted to `$HOME` first (quoting suppresses tilde
# expansion).  Validation (__bu_location_validate_path_expr) is the security
# boundary: only $VAR/parameter expansion survives to this point.
#
# *Params*:
# - `$1`: unexpanded path expression
#
# *Returns*:
# - BU_RET: expanded path (scalar)
# - 0 on success, 1 if expansion fails
# ```
__bu_location_expand_path()
{
    local expr=$1
    case "$expr" in
    '~')   expr='$HOME' ;;
    '~/')  expr='$HOME/' ;;
    '~/'*) expr='$HOME'/"${expr#~/}" ;;
    esac

    local resolved
    if ! eval "resolved=\"$expr\"" 2>/dev/null
    then
        bu_log_err "Could not expand location path expression: $1"
        return 1
    fi
    BU_RET=("$resolved")
    return 0
}

# ```
# *Description*:
# Resolve a name (and optional kind) to its storage key in BU_LOCATION_REGISTRY.
# Alias-aware.  A --kind mismatch is an error unless a kind:name sibling of the
# requested kind exists.
#
# *Params*:
# - `$1`: name or alias
# - `--kind KIND` (optional)
#
# *Returns*:
# - BU_RET: storage key
# - 0 on success, 1 on unknown name / kind mismatch
# ```
__bu_location_resolve_key()
{
    local name=$1
    shift
    local kind=
    while (($#))
    do
        case "$1" in
        --kind) kind=$2; shift 2 ;;
        *) shift ;;
        esac
    done

    local canonical=${BU_LOCATION_ALIASES[$name]:-$name}
    local key=$canonical
    local entry_kind=${BU_LOCATION_REGISTRY[$key]:-}

    if [[ -z "$entry_kind" ]]
    then
        bu_log_err "Unknown location[$name] (list with: bu get-location-registry)"
        return 1
    fi

    if [[ -n "$kind" && "$entry_kind" != "$kind" ]]
    then
        local sibling="$kind:$canonical"
        if [[ -n "${BU_LOCATION_REGISTRY[$sibling]:-}" ]]
        then
            key=$sibling
        else
            bu_log_err "location[$name] is kind[$entry_kind], not [$kind]"
            return 1
        fi
    fi

    BU_RET=("$key")
    return 0
}

# ```
# *Description*:
# Clear an entry's registry slot, all its properties, and every alias that
# points at it.  Used by overwrite and unregister so stale resolver/path/alias
# data never lingers.
#
# *Params*:
# - `$1`: storage key
# ```
__bu_location_clear_entry()
{
    local key=$1
    local prop
    for prop in path resolver description tags on_enter source \
                repo_remote repo_gh_host repo_gh_slug repo_default_branch \
                repo_gh_slug_cached repo_gh_host_cached
    do
        unset "BU_LOCATION_PROPERTIES[$key,$prop]"
    done
    unset "BU_LOCATION_REGISTRY[$key]"
    local a
    for a in "${!BU_LOCATION_ALIASES[@]}"
    do
        if [[ "${BU_LOCATION_ALIASES[$a]}" == "$key" ]]
        then
            unset "BU_LOCATION_ALIASES[$a]"
        fi
    done
}

# ```
# *Description*:
# Register a named location.
#
# *Params*:
# - `$1`: name
# - `--kind dir|file|multi` (default dir)
# - `--path 'EXPR'`       unexpanded path expression (mutually exclusive with --resolver)
# - `--resolver FN`       resolver function (returns BU_RET scalar/array)
# - `--alias A`           repeatable
# - `--description TEXT`
# - `--tags CSV`
# - `--on-enter FN`       dir kind only
#
# *Returns*:
# - BU_RET: storage key (name, or kind:name sibling)
# - 0 on success, 1 on invalid registration
# ```
bu_location_register()
{
    local name=$1
    shift
    local kind=dir
    local path_expr=
    local resolver=
    local on_enter=
    local description=
    local tags=
    local -a aliases=()
    while (($#))
    do
        case "$1" in
        --kind)        kind=$2; shift 2 ;;
        --path)        path_expr=$2; shift 2 ;;
        --resolver)    resolver=$2; shift 2 ;;
        --alias)       aliases+=("$2"); shift 2 ;;
        --description) description=$2; shift 2 ;;
        --tags)        tags=$2; shift 2 ;;
        --on-enter)    on_enter=$2; shift 2 ;;
        *) bu_log_err "bu_location_register: unknown option[$1]"; return 1 ;;
        esac
    done

    if [[ -z "$name" ]]
    then
        bu_log_err "bu_location_register: empty name"
        return 1
    fi

    case "$kind" in
    dir|file|multi) ;;
    *) bu_log_err "bu_location_register: invalid kind[$kind] for [$name]"; return 1 ;;
    esac

    if [[ -n "$path_expr" && -n "$resolver" ]]
    then
        bu_log_err "bu_location_register[$name]: --path and --resolver are mutually exclusive"
        return 1
    fi
    if [[ -z "$path_expr" && -z "$resolver" ]]
    then
        bu_log_err "bu_location_register[$name]: exactly one of --path or --resolver is required"
        return 1
    fi

    if [[ -n "$on_enter" && "$kind" != dir ]]
    then
        bu_log_err "bu_location_register[$name]: --on-enter is only valid for kind dir"
        return 1
    fi

    if [[ -n "$path_expr" ]] && ! __bu_location_validate_path_expr "$path_expr"
    then
        bu_log_err "bu_location_register[$name]: path expression contains forbidden characters (\$(, backtick, ;, &, |, <, >, newline): $path_expr"
        return 1
    fi

    # Same name + same kind → overwrite.  Different kind → kind:name sibling.
    local existing_kind=${BU_LOCATION_REGISTRY[$name]:-}
    local key=$name
    if [[ -n "$existing_kind" && "$existing_kind" != "$kind" ]]
    then
        key="$kind:$name"
    fi

    if [[ -n "${BU_LOCATION_REGISTRY[$key]:-}" ]]
    then
        __bu_location_clear_entry "$key"
    fi

    BU_LOCATION_REGISTRY[$key]=$kind
    BU_LOCATION_PROPERTIES[$key,path]=$path_expr
    BU_LOCATION_PROPERTIES[$key,resolver]=$resolver
    BU_LOCATION_PROPERTIES[$key,description]=$description
    BU_LOCATION_PROPERTIES[$key,tags]=$tags
    BU_LOCATION_PROPERTIES[$key,on_enter]=$on_enter

    __bu_location_provenance
    BU_LOCATION_PROPERTIES[$key,source]=$BU_RET

    local a
    for a in "${aliases[@]}"
    do
        BU_LOCATION_ALIASES[$a]=$key
    done

    BU_RET=("$key")
    return 0
}

# ```
# *Description*:
# Resolve a location to its target path(s).
#
# *Params*:
# - `$1`: name or alias
# - `--kind KIND` (optional)
# - `--no-verify`  skip the existence check (dir/file kinds)
#
# *Returns*:
# - BU_RET: resolved path (scalar for dir/file, array for multi)
# - 0 on success, 1 on error
# ```
bu_location_resolve()
{
    local name=$1
    shift
    local kind=
    local no_verify=false
    while (($#))
    do
        case "$1" in
        --kind)      kind=$2; shift 2 ;;
        --no-verify) no_verify=true; shift ;;
        *) bu_log_err "bu_location_resolve: unknown option[$1]"; return 1 ;;
        esac
    done

    __bu_location_resolve_key "$name" ${kind:+--kind "$kind"} || return 1
    local key=$BU_RET
    local entry_kind=${BU_LOCATION_REGISTRY[$key]}

    local resolver=${BU_LOCATION_PROPERTIES[$key,resolver]:-}
    if [[ -n "$resolver" ]]
    then
        BU_RET=()
        if ! "$resolver" "$name"
        then
            return 1
        fi
    else
        local path_expr=${BU_LOCATION_PROPERTIES[$key,path]:-}
        __bu_location_expand_path "$path_expr" || return 1
    fi

    if ! "$no_verify"
    then
        local src=${BU_LOCATION_PROPERTIES[$key,source]:-?}
        case "$entry_kind" in
        dir)
            if [[ ! -d "${BU_RET[0]}" ]]
            then
                bu_log_err "location[$name] directory missing[${BU_RET[0]}] (registered in $src)"
                return 1
            fi
            ;;
        file)
            if [[ ! -f "${BU_RET[0]}" ]]
            then
                bu_log_err "location[$name] file missing[${BU_RET[0]}] (registered in $src)"
                return 1
            fi
            ;;
        esac
    fi

    return 0
}

# ```
# *Description*:
# List location names (newline on stdout — the completion feed).
# Kind-qualified siblings list under their plain name, deduplicated.
#
# *Params*:
# - `--kind K`        filter by kind
# - `--tag T`         filter by tag (comma-separated CSV)
# - `--with-aliases`  also include alias names
# ```
bu_location_names()
{
    local kind=
    local tag=
    local with_aliases=false
    while (($#))
    do
        case "$1" in
        --kind)          kind=$2; shift 2 ;;
        --tag)           tag=$2; shift 2 ;;
        --with-aliases)  with_aliases=true; shift ;;
        *) bu_log_err "bu_location_names: unknown option[$1]"; return 1 ;;
        esac
    done

    local -A seen=()
    local -a out=()
    local key k display
    for key in "${!BU_LOCATION_REGISTRY[@]}"
    do
        k=${BU_LOCATION_REGISTRY[$key]}
        [[ -n "$kind" && "$k" != "$kind" ]] && continue
        if [[ -n "$tag" ]]
        then
            __bu_location_tag_match "${BU_LOCATION_PROPERTIES[$key,tags]:-}" "$tag" || continue
        fi
        display=$key
        [[ "$key" == *:* ]] && display=${key#*:}
        [[ -n "${seen[$display]:-}" ]] && continue
        seen[$display]=1
        out+=("$display")
    done

    if "$with_aliases"
    then
        local a target
        for a in "${!BU_LOCATION_ALIASES[@]}"
        do
            target=${BU_LOCATION_ALIASES[$a]}
            k=${BU_LOCATION_REGISTRY[$target]:-}
            [[ -n "$kind" && "$k" != "$kind" ]] && continue
            if [[ -n "$tag" ]]
            then
                __bu_location_tag_match "${BU_LOCATION_PROPERTIES[$target,tags]:-}" "$tag" || continue
            fi
            out+=("$a")
        done
    fi

    if ((${#out[@]} > 0))
    then
        printf '%s\n' "${out[@]}" | sort -u
    fi
    return 0
}

# ```
# *Description*:
# Resolve a dir location, cd into it, and run its on-enter callback.  The
# goto primitive; callers must be source-dispatch so the cd takes effect.
#
# *Params*:
# - `$1`: name or alias
# - `--no-enter-hook`: skip the on-enter callback
# ```
bu_location_enter()
{
    local name=$1
    shift
    local no_enter_hook=false
    while (($#))
    do
        case "$1" in
        --no-enter-hook) no_enter_hook=true; shift ;;
        *) bu_log_err "bu_location_enter: unknown option[$1]"; return 1 ;;
        esac
    done

    __bu_location_resolve_key "$name" --kind dir || return 1
    local key=$BU_RET

    bu_location_resolve "$name" --kind dir || return 1
    local dir=${BU_RET[0]}

    cd "$dir" || return 1

    if ! "$no_enter_hook"
    then
        local hook=${BU_LOCATION_PROPERTIES[$key,on_enter]:-}
        if [[ -n "$hook" ]]
        then
            if ! "$hook" "$name" "$dir"
            then
                bu_log_warn "on-enter hook[$hook] failed for location[$name]"
            fi
        fi
    fi
    return 0
}

# ```
# *Description*:
# Remove a location entry, its properties, and all aliases pointing at it.
# ```
bu_location_unregister()
{
    local name=$1
    if [[ -z "${BU_LOCATION_REGISTRY[$name]:-}" ]]
    then
        bu_log_warn "location[$name] is not registered"
        return 1
    fi
    __bu_location_clear_entry "$name"
    return 0
}

# ```
# *Description*:
# Source the user-local location file.  Missing file is not an error and this
# never returns non-zero.  Called from bu_entrypoint.sh AFTER module preinits
# so user registrations override code defaults (last write wins).
# ```
bu_location_source_local_file()
{
    local file=${BU_LOCATION_LOCAL_FILE:-"$BU_DIR"/config/bu_locations_local.sh}
    if [[ ! -f "$file" ]]
    then
        return 0
    fi
    bu_scope_push
    bu_scoped_set +e
    source "$file" || bu_log_warn "Failed to source location file: $file"
    bu_scope_pop
    return 0
}
