if false; then
source ../../bu_custom_source.sh
source ./bu_core_var.sh
# Note: static.sh should be sourced outside of this file!
source ../../config/bu_config_static.sh
# Note: dynamic.sh should be sourced outside of this file!
source ../../config/bu_config_dynamic.sh
source ./bu_core_base.sh
fi

function __bu_compat_macos()
{
    # https://formulae.brew.sh/formula/findutils
    if command -v gfind &>/dev/null; then
        alias find=gfind
    else
        bu_log_warn "gfind not found, -printf will break"
    fi

    if command -v gwak &>/dev/null; then
        alias awk=gwak
    else
        bu_log_warn "gawk not found" >&2
    fi
}


if "$BU_ENV_IS_MACOS"
then
    __bu_compat_macos
fi
