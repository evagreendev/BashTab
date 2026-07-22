# ```
# Capability detection and platform identification.
#
# Probes the environment once at init time and produces a canonical picture
# of what is available — binaries, platform identity, and distro-specific
# package names.  The rest of the framework consults BU_CAP and BU_PLATFORM_*
# instead of scattering ad-hoc `command -v` calls.
#
# Variables set (all global, exported where noted):
#   BU_PLATFORM_ID         e.g. "ubuntu", "fedora", "arch", ""
#   BU_PLATFORM_FAMILY     e.g. "debian", "rhel fedora" — space-separated, from ID_LIKE
#   BU_PLATFORM_NAME       e.g. "Ubuntu 24.04.1 LTS" from VERSION / PRETTY_NAME
#   BU_CAP                 associative array: capability name → binary path (or "")
#   BU_PKG_MAP             associative array: binary → "distro:pkg distro:pkg … pip:pkg"
#   BU_COMMAND_UNAVAILABLE associative array: command → reason (populated by registration)
# ```

if false; then
    source ./bu_core_base.sh
fi

# ── Platform detection ────────────────────────────────────────────────

bu_cap_detect_platform()
{
    BU_PLATFORM_ID=
    BU_PLATFORM_FAMILY=
    BU_PLATFORM_NAME=

    if [[ -f /etc/os-release ]]; then
        local id= id_like= name= version= pretty=
        # Evaluate os-release safely into local variables
        eval "$(grep -E '^(ID|ID_LIKE|NAME|VERSION|PRETTY_NAME|VERSION_ID)=' /etc/os-release \
            | sed -e 's/^ID=/id=/' -e 's/^ID_LIKE=/id_like=/' \
                  -e 's/^NAME=/name=/' -e 's/^VERSION_ID=/version=/' \
                  -e 's/^VERSION=/version=/' -e 's/^PRETTY_NAME=/pretty=/')"

        # Strip quotes
        id=${id//\"/}
        id_like=${id_like//\"/}
        name=${name//\"/}
        version=${version//\"/}
        pretty=${pretty//\"/}

        BU_PLATFORM_ID=$id
        BU_PLATFORM_FAMILY=${id_like:-$id}
        if [[ -n "$pretty" ]]; then
            BU_PLATFORM_NAME=$pretty
        elif [[ -n "$name" && -n "$version" ]]; then
            BU_PLATFORM_NAME="$name $version"
        elif [[ -n "$name" ]]; then
            BU_PLATFORM_NAME=$name
        fi
    fi
}

# ── Binary probing ────────────────────────────────────────────────────

# ```
# Probe for a single capability binary.
#
# Params:
# - $1: capability name (key in BU_CAP)
# - $2: primary binary name to look for
# - $3: fallback binary name (optional)
#
# Returns: 0 always. Presence/absence is recorded in BU_CAP[$cap] instead of
# the exit status, because this runs while bu_entrypoint.sh is being sourced —
# a non-zero return here would abort the whole activation under `set -e`.
# ```
bu_cap_probe()
{
    local cap=$1 binary=$2 fallback=${3:-}
    if command -v "$binary" &>/dev/null; then
        BU_CAP[$cap]=$(command -v "$binary")
    elif [[ -n "$fallback" ]] && command -v "$fallback" &>/dev/null; then
        BU_CAP[$cap]=$(command -v "$fallback")
    else
        BU_CAP[$cap]=
    fi
    return 0
}

# ```
# Probe all known capabilities.  Called once at init.
# ```
bu_cap_probe_all()
{
    bu_cap_probe fzf      fzf
    bu_cap_probe jq       jq
    bu_cap_probe node     node
    bu_cap_probe jc       jc
    bu_cap_probe docker   docker
    bu_cap_probe systemctl systemctl
    bu_cap_probe dpkg     dpkg
    bu_cap_probe rpm      rpm
    bu_cap_probe pacman   pacman
    bu_cap_probe apk      apk
    bu_cap_probe bats     bats
    bu_cap_probe gawk     gawk     awk
    bu_cap_probe gfind    gfind    find
}

# ── Install hints ─────────────────────────────────────────────────────

# Binary → "distro:pkg distro:pkg …" mapping.
# The lookup function matches the current BU_PLATFORM_ID first, then tries
# each member of BU_PLATFORM_FAMILY, and finally falls back to the first
# entry or a generic "pip:xxx" hint.
declare -A -g BU_PKG_MAP=(
    [jq]="debian:jq ubuntu:jq fedora:jq arch:jq alpine:jq"
    [fzf]="debian:fzf ubuntu:fzf fedora:fzf arch:fzf alpine:fzf"
    [node]="debian:nodejs ubuntu:nodejs fedora:nodejs arch:nodejs alpine:nodejs"
    [jc]="pip:jc debian:pipx-fed-jc ubuntu:pipx-fed-jc"
    [docker]="debian:docker.io ubuntu:docker.io fedora:docker arch:docker alpine:docker"
    [dpkg]="debian:dpkg ubuntu:dpkg"
    [rpm]="fedora:rpm arch:rpm"
    [pacman]="arch:pacman"
    [bats]="debian:bats ubuntu:bats fedora:bats arch:bats alpine:bats"
    [gawk]="debian:gawk ubuntu:gawk fedora:gawk arch:gawk alpine:gawk"
    [gfind]="debian:findutils ubuntu:findutils fedora:findutils arch:findutils alpine:findutils"
)

# ```
# Return a human-readable install instruction for a capability.
#
# Params:
# - $1: capability name (e.g. "jq", "fzf")
#
# Returns:
# - BU_RET: install hint string, or empty if the cap is already present
# ```
bu_install_hint()
{
    local cap=$1
    BU_RET=

    # Already installed — no hint needed
    if [[ -n "${BU_CAP[$cap]:-}" ]]; then
        return 0
    fi

    local pkg_entry=${BU_PKG_MAP[$cap]:-}
    if [[ -z "$pkg_entry" ]]; then
        BU_RET="no install hint available"
        return 0
    fi

    # Try exact platform match first
    local pkg
    for entry in $pkg_entry; do
        local distro=${entry%%:*}
        pkg=${entry#*:}
        if [[ "$distro" == "$BU_PLATFORM_ID" ]]; then
            bu_install_hint_for_distro "$distro" "$pkg"
            return 0
        fi
    done

    # Try family members
    if [[ -n "$BU_PLATFORM_FAMILY" ]]; then
        local fam
        for fam in $BU_PLATFORM_FAMILY; do
            for entry in $pkg_entry; do
                distro=${entry%%:*}
                pkg=${entry#*:}
                if [[ "$distro" == "$fam" ]]; then
                    bu_install_hint_for_distro "$distro" "$pkg"
                    return 0
                fi
            done
        done
    fi

    # Fallback: first non-pip entry, or the pip one
    for entry in $pkg_entry; do
        distro=${entry%%:*}
        pkg=${entry#*:}
        if [[ "$distro" != "pip" ]]; then
            bu_install_hint_for_distro "$distro" "$pkg"
            return 0
        fi
    done

    # Last resort: pip
    for entry in $pkg_entry; do
        distro=${entry%%:*}
        pkg=${entry#*:}
        if [[ "$distro" == "pip" ]]; then
            BU_RET="pip install $pkg"
            return 0
        fi
    done

    BU_RET="no install hint available"
}

bu_install_hint_for_distro()
{
    local distro=$1 pkg=$2
    case "$distro" in
        debian|ubuntu)  BU_RET="sudo apt install $pkg" ;;
        fedora|rhel)    BU_RET="sudo dnf install $pkg" ;;
        arch)           BU_RET="sudo pacman -S $pkg" ;;
        alpine)         BU_RET="sudo apk add $pkg" ;;
        pip)            BU_RET="pip install $pkg" ;;
        *)              BU_RET="install $pkg" ;;
    esac
}

# ── Global registry of unavailable commands ───────────────────────────
# Populated by __bu_init_env_commands during registration.
# Maps command name → human-readable reason.
declare -A -g BU_COMMAND_UNAVAILABLE=()

# ── Compatibility cache ───────────────────────────────────────────────
# Caches --is-compatible probe results across shell sessions.
# Avoids forking 30+ bash processes on every `source ./activate`.
# Cache lives at $BU_CACHE_DIR/compat.cache and is invalidated when:
#   - Platform / bash version / PATH changes
#   - Any command script is added, removed, or modified

BU_COMPAT_CACHE_FILE=$BU_CACHE_DIR/compat.cache

# ```
# Generate a fingerprint of everything that affects --is-compatible results:
# kernel, distro, bash version, PATH, and all command scripts (paths + mtimes).
# When this changes, the cache must be rebuilt.
#
# Returns: BU_RET = md5 hash string (empty if md5sum unavailable)
# ```
bu_cap_cache_fingerprint()
{
    BU_RET=
    if ! command -v md5sum &>/dev/null; then
        return 1
    fi
    local hash_input
    hash_input=$(
        uname -srm
        cat /etc/os-release 2>/dev/null
        echo "BASH=$BASH_VERSION"
        echo "PATH=$PATH"
        local dir
        for dir in "${!BU_COMMAND_SEARCH_DIRS[@]}"; do
            find "$dir" -type f -printf '%p %T@\n' 2>/dev/null | sort
        done
    )
    BU_RET=$(echo "$hash_input" | md5sum | cut -d' ' -f1)
}

# ```
# Load the cached --is-compatible results.  Reads the cache file and
# populates BU_COMMAND_UNAVAILABLE from it.  Registered commands are
# unaffected — this only restores the "skip" list.
#
# Params:
# - $1: current fingerprint to validate against the cached one
#
# Returns: 0 if cache was loaded and fingerprint matched, 1 otherwise
# ```
bu_cap_cache_load()
{
    local current_fp=$1
    if [[ ! -f "$BU_COMPAT_CACHE_FILE" ]]; then
        return 1
    fi

    # Read the cached fingerprint (first line: #:fp:<hash>)
    local cached_fp
    read -r cached_fp < "$BU_COMPAT_CACHE_FILE"
    cached_fp=${cached_fp###:fp:}

    if [[ "$cached_fp" != "$current_fp" ]]; then
        bu_log_info "Compat cache fingerprint mismatch — will re-probe"
        return 1
    fi

    # Fingerprint matches — load entries
    local line command exit_code reason
    while IFS=$'\t' read -r command exit_code reason; do
        # Skip header / empty lines
        [[ -z "$command" || "$command" == \#* ]] && continue
        if [[ "$exit_code" != "0" ]]; then
            BU_COMMAND_UNAVAILABLE[$command]=$reason
        fi
    done < "$BU_COMPAT_CACHE_FILE"

    bu_log_info "Compat cache loaded (${#BU_COMMAND_UNAVAILABLE[@]} unavailable)"
    return 0
}

# ```
# Save the current --is-compatible results and fingerprint to the cache file.
# Reads BU_COMMAND_UNAVAILABLE (populated by the registration loop) and
# writes tab-separated entries.
#
# Params:
# - $1: fingerprint to embed in the cache header
# ```
bu_cap_cache_save()
{
    local fp=$1
    bu_mkdir "$(dirname "$BU_COMPAT_CACHE_FILE")"

    {
        printf '#:fp:%s\n' "$fp"
        local cmd reason
        # Write unavailable commands
        for cmd in "${!BU_COMMAND_UNAVAILABLE[@]}"; do
            printf '%s\t1\t%s\n' "$cmd" "${BU_COMMAND_UNAVAILABLE[$cmd]}"
        done
        # Write commands that ARE available (so the cache knows they were checked)
        local cmd
        for cmd in "${!BU_COMMANDS[@]}"; do
            # Only include gated commands (scripts that declare --is-compatible)
            local script_path=${BU_COMMANDS[$cmd]}
            if [[ -f "$script_path" ]] && grep -qE -- '--is-compatible[)"]' "$script_path" 2>/dev/null; then
                printf '%s\t0\t\n' "$cmd"
            fi
        done
    } > "$BU_COMPAT_CACHE_FILE"

    bu_log_info "Compat cache saved ($(grep -cv '^#' "$BU_COMPAT_CACHE_FILE" || true) entries)"
}

# ```
# Force-invalidate the compat cache so the next activation re-probes.
# ```
bu_cap_cache_invalidate()
{
    rm -f "$BU_COMPAT_CACHE_FILE"
    bu_log_info "Compat cache invalidated"
}

# ── Initialization ────────────────────────────────────────────────────

bu_cap_init()
{
    declare -A -g BU_CAP=()

    bu_cap_detect_platform
    bu_cap_probe_all

    bu_log_info "Platform: ${BU_PLATFORM_NAME:-unknown} (${BU_PLATFORM_ID:-unknown})"
    local cap
    for cap in "${!BU_CAP[@]}"; do
        if [[ -n "${BU_CAP[$cap]}" ]]; then
            bu_log_debug "  $cap = ${BU_CAP[$cap]}"
        else
            bu_log_debug "  $cap = (missing)"
        fi
    done
}
