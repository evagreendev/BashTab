---
layout: page
title: "How To: Using BashTab as a project dependency"
permalink: /how-to-02-BashTab-workflow/
nav-order: 4
---

This guide shows how to embed BashTab in your own project using git submodules and the module system. We'll use a Python project as the running example, but the pattern applies to any language.

## 1. Add BashTab as a submodule

```sh
cd your-project
git submodule add https://github.com/sunjc826/BashTab.git deps/bash-tab
```

## 2. Scaffold your module

```sh
source deps/bash-tab/activate
bu new-module --name myproject
```

This creates:

```
myproject/
├── activate
├── myproject_bu_module.sh
├── myproject_bu_preinit.sh
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

`myproject/activate` bootstraps the full environment — BashTab, your module, Python venv, and anything else your project needs:

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

    source "$BU_DIR"/bu_entrypoint.sh

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
bu module-list              # verify your module is loaded
bu deploy --help            # auto-generated help
```

## Module registration (updated pattern)

The module script (`myproject_bu_module.sh`) registers itself with the new `__bu_module_register` API:

```sh
#!/usr/bin/env bash
myproject_DIR=$(realpath -- "$(dirname -- "${BASH_SOURCE}")")
__bu_module_register "myproject" "0.1.0" "$myproject_DIR/myproject_bu_preinit.sh"
```

This makes the module visible to `bu module-list` and future module introspection tools. The legacy raw-array pattern still works but won't appear in module listings.

## Key concepts

| Concept | Purpose |
|---|---|
| `BU_MODULE_PATH` | Colon-separated list of module scripts. Add yours here. |
| Module script | Registers preinit callbacks. Sourced once at shell init. |
| Preinit callback | Runs during `bu import-environment`. Registers commands, aliases, keybindings. |
| `activate` | Bootstrap script. Users `source ./activate` to enter the project environment. |
| `commands/` | Directory of bu subcommand scripts. Scanned by `bu import-environment -c`. |
