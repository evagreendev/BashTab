---
layout: page
title: "How To: Using BashTab as a project dependency"
permalink: /how-to-02-BashTab-workflow/
nav_order: 4
---

This guide shows how to embed BashTab in your own project using git submodules and the module system. We'll use a Python project as the running example, but the pattern applies to any language.

## 1. Add BashTab as a submodule

```sh
cd your-project
git submodule add https://github.com/evagreendev/BashTab.git deps/bash-tab
```

## Library vs Binary

BashTab modules can be used in two ways, just like Rust crates:

| Mode | Your module acts as… | Entrypoint | Caching |
|------|----------------------|------------|---------|
| **Binary** | A standalone shell environment | `activate` script | Sets `BU_TOP_LEVEL_MODULE`, calls `bu_mark_load_complete` |
| **Library** | A dependency of another project | `*_bu_module.sh` (registered in `BU_MODULE_PATH`) | Inherits the host's cache key |

The same module can do both — `activate` is the "binary" entrypoint, `*_bu_module.sh` is the "library" entrypoint. Only the binary/top-level calls `bu_mark_load_complete`.

## 2. Scaffold your module

```sh
source deps/bash-tab/activate
bu new-module --name myproject
```

This creates:

```
myproject/
├── activate                      ← "binary" entrypoint (sets BU_TOP_LEVEL_MODULE)
├── myproject_bu_module.sh        ← "library" registration (__bu_module_register)
├── myproject_bu_preinit.sh       ← registers command dirs (runs in both modes)
└── commands/
```

## 3. Customize the preinit callback

`myproject_bu_preinit.sh` is sourced during `bu import-environment`. This is where you register your project's commands, set up shell integrations, and load language-specific completions:

```sh
#!/usr/bin/env bash
source "$BU_NULL"
bu_pushd_current "$BASH_SOURCE"

# Register commands from the local commands/ directory
bu import-environment +i -c ./commands -ns prefix

# Language-specific completions
if command -v uv &>/dev/null; then
    eval "$(uv generate-shell-completion bash)"
fi

bu_popd_silent
```

## 4. Customize the activate script

`myproject/activate` is the "binary" entrypoint — it sets `BU_TOP_LEVEL_MODULE`
so the command registry can be cached, and calls `bu_mark_load_complete` after
initialization.  Bootstrap the full environment — BashTab, your module, Python
venv, and anything else your project needs:

```sh
#!/usr/bin/env bash
function myproject_activate()
{
    local myproject_invocation_dir=$PWD
    pushd "$(dirname -- "${BASH_SOURCE}")" &>/dev/null
    local myproject_dir=$PWD

    eval "$(fzf --bash)"

    if command -v bu &>/dev/null; then
        bu import-environment --reset-leaky --no-init
    fi

    if [[ "$BU_MODULE_PATH" != *myproject_bu_module.sh* ]]; then
        BU_MODULE_PATH+=:$myproject_dir/myproject_bu_module.sh
    fi

    # Set the top-level module key so the command registry can be cached.
    # Must be set BEFORE sourcing bu_entrypoint.sh.
    export BU_TOP_LEVEL_MODULE="${BU_TOP_LEVEL_MODULE:-myproject}"

    source "$BU_DIR"/bu_entrypoint.sh

    # Cache the command registry so subsequent activations skip the scan.
    # No-op if the cache was already loaded.
    bu_mark_load_complete

    bu_scope_push_function
    bu_scope_add_cleanup bu_popd_silent

    # Python venv
    if [[ -d .venv ]]; then
        source .venv/bin/activate
    fi

    bu_scope_pop_function
}

myproject_activate "$@"
```

## 5. Add custom commands

```sh
source ./activate
bu new-command --dir commands --name deploy
bu new-command --dir commands --name run-tests --source
```

Now `bu deploy` and `bu run-tests` are available with autocomplete.

## 6. Use it

```sh
cd your-project
source ./activate
bu                          # see your commands alongside built-ins
bu get-module              # verify your module is loaded
bu deploy --help            # auto-generated help
```

### Cache management

After the first activation, the command registry is cached. Subsequent shell
startups load from the cache and skip the scan entirely.

```sh
bu get-cache                # list cached projects
bu clear-cache myproject    # invalidate after adding/removing commands
bu clear-cache --all        # invalidate all caches
```

## 7. Use your module as a library

If another project wants to use your module as a dependency (library mode),
they add your `*_bu_module.sh` to their `BU_MODULE_PATH`.  Your preinit
callbacks run during their init, and your commands appear alongside theirs.
They do NOT source your `activate` — that would make your module the
top-level "binary" and override their cache key.

## Module registration (updated pattern)

The module script (`myproject_bu_module.sh`) registers itself with the new `__bu_module_register` API:

```sh
#!/usr/bin/env bash
myproject_DIR=$(realpath -- "$(dirname -- "${BASH_SOURCE}")")
__bu_module_register "myproject" "0.1.0" "$myproject_DIR/myproject_bu_preinit.sh"
```

This makes the module visible to `bu get-module` and future module introspection tools. The legacy raw-array pattern still works but won't appear in module listings.

## Key concepts

| Concept | Purpose |
|---|---|
| `BU_MODULE_PATH` | Colon-separated list of module scripts. Add yours here. |
| Module script | Registers preinit callbacks. Sourced once at shell init. |
| Preinit callback | Runs during `bu import-environment`. Registers commands, aliases, keybindings. |
| `activate` | Bootstrap script. Users `source ./activate` to enter the project environment. |
| `commands/` | Directory of bu subcommand scripts. Scanned by `bu import-environment -c`. |
