# bash-ide source=../../bu_custom_source.sh
# bash-ide source=./bu_core_var.sh
# Note: static.sh should be sourced outside of this file!
# bash-ide source=../../config/bu_config_static.sh
# Note: dynamic.sh should be sourced outside of this file!
# bash-ide source=../../config/bu_config_dynamic.sh
# bash-ide source=./bu_core_base.sh

bu_env_prepend_path "$BU_SHIMS_DIR"

function __bu_compat_shim_install()
{
    local shim_name=$1
    local wrapped_binary=$2

    local shim_location=$BU_SHIMS_DIR/$shim_name

    if [[ -e "$shim_location" ]]
    then
        return
    fi

    # Use symlinks
    local binary_type=$(type -t "$wrapped_binary")
    if [[ "$binary_type" != file ]]
    then
        bu_log_err "Binary type [$binary_type] unsupported, only file is supported"
        return
    fi
    local binary_fullpath
    if ! binary_fullpath="$(command -v "$wrapped_binary")"
    then
        bu_log_err "Failed to find $wrapped_binary"
        return
    fi

    if ! ln -sf "$binary_fullpath" "$shim_location"
    then
        bu_log_err "Failed to symlink $shim_location -> $binary_fullpath"
        return
    fi

    bu_log_info "Symlinking $shim_location -> $binary_fullpath"
}

function __bu_compat_macos()
{
    # https://formulae.brew.sh/formula/findutils
    if command -v gfind &>/dev/null; then
        __bu_compat_shim_install find gfind
    else
        bu_log_warn "gfind not found, -printf will break"
    fi

    if command -v gawk &>/dev/null; then
        __bu_compat_shim_install awk gawk
    else
        bu_log_warn "gawk not found" >&2
    fi
}


if "$BU_ENV_IS_MACOS"
then
    __bu_compat_macos
fi
