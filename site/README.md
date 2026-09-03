# Site customization

This directory holds **fleet-shared environment glue** for BashTab: files that
must apply to *every* project embedding this checkout, regardless of which
top-level module activates.

`bu_entrypoint.sh` sources `site/*.sh` in glob order (profile.d-style) **after**
the machine-local config (`config/bu_config_local.sh`) and **before** capability
probing (`bu_cap_init`). A missing or empty directory is a no-op — behavior is
identical to not having this directory at all.

## Two layers

| Layer | Path | Scope | Version control |
|-------|------|-------|-----------------|
| **Site** | `site/*.sh` | A fleet of hosts sharing one config (same module system, same package tool) | **Committed** and deployed with the checkout |
| **Local** | `config/bu_config_local.sh` | A genuinely per-machine setting (managed by `bu set-config`) | Gitignored |

A "site" is by definition shared across many hosts, so its glue belongs in the
repository: a downstream fork/branch commits its site files once, and every
host the checkout is cloned to gets them. Do **not** gitignore `site/*.sh`.

## Sourcing order

1. `config/bu_config_local.sh` (per-machine)
2. `site/*.sh` (fleet-shared, glob order)
3. `config/bu_config_static.sh` and `config/bu_config_dynamic.sh` (framework defaults)

## Capability resolver hook

The primary use case is making on-demand binaries visible to capability
probing. On managed environments (HPC clusters, environment-modules/Lmod
sites), tools like `fzf`, `jq`, and `node` are absent from the base shell's
`PATH` until a site-specific load command runs.

Set `BU_CAP_MISS_RESOLVER` to the name of a function. When `bu_cap_probe`
misses a capability (both the primary and fallback binaries are absent), it
calls the resolver as:

```bash
"$BU_CAP_MISS_RESOLVER" <cap> <binary>
```

with stdout/stderr discarded, then re-runs `command -v`. If the resolver makes
the binary available (e.g. by running `module load` and updating `PATH`), the
capability is populated normally; otherwise it stays empty. The resolver is
never allowed to abort activation — a failing or no-op resolver leaves the
framework in its degraded-but-working baseline.

Example:

```bash
# site/00_hpc_module.sh
__bu_site_resolve_module() {
    local cap=$1 binary=$2
    # Make the binary available on demand via the site's module system.
    module load "$binary" 2>/dev/null || return 1
}

BU_CAP_MISS_RESOLVER=__bu_site_resolve_module
```

## Shopt synopsis overrides

`bu get-shopt-option` ships a static synopsis table covering vanilla bash's
shopt options. Distros that patch bash with extra options (e.g. Red Hat-family
bash ships a downstream `syslog_history` option) would otherwise list those
options with a blank description.

Populate the global associative array `BU_SHOPT_SYNOPSIS_OVERRIDES` to add or
reword descriptions. Its entries merge over the static table; leave it
unset/empty for byte-identical vanilla behavior.

```bash
# site/01_shopt_synopsis.sh
# Red Hat-family bash ships a downstream shopt option absent from the vanilla
# table; give it a description (and optionally reword a vanilla one).
declare -A -g BU_SHOPT_SYNOPSIS_OVERRIDES=(
    [syslog_history]="Log shell commands to syslog when enabled"
    # [nullglob]="Patterns matching nothing expand to the empty string"
)
```

The `declare -A -g` is required: `site/*.sh` is sourced through BashTab's
custom `source` function, so a bare `declare -A` would create a function-local
that vanishes when the file returns (see the notes below).

## Notes for site file authors

- `site/*.sh` is sourced through BashTab's custom `source` function, so a
  top-level `declare` (without `-g`) creates a function-local that vanishes
  when the file returns. Use `declare -g` (or plain assignments) for globals.
- Keep files idempotent: they are re-sourced on every activation (no
  `--__bu-once`), so prefer function definitions and exported variables.
