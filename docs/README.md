# BashTab

**BashTab** is a Bash scripting framework that makes shell development feel like a modern CLI platform. Command scripts, argument parsing, autocompletion, module loading, and interactive fzf previews — all in pure Bash.

![BashTab demo: command listing, fzf completion, structured-output pipeline, and option hints](./demo.gif)

## Quick start

```sh
./setup                       # one-time: initialise submodules, build Fig specs
source ./activate            # load BashTab into your shell
bu                            # list commands
bu new-module --name myapp    # scaffold a module
```

Add this to your `~/.bashrc` to load BashTab automatically:
```sh
source /path/to/BashTab/activate
```

## Highlights

### ⌨️ IDE-style autocompletion
- **fzf dropdown** aligned under the cursor with syntax-highlighted preview line
- **Color-coded metadata**: file types, sizes, symlink targets, option type tags
- **Tree-sitter parser** for accurate CST-based tokenization of pipes, substitutions, and variables
- **Lazy completion generation** — no compilation step, modify scripts and see suggestions instantly

### 📊 Structured output (PowerShell-inspired)
- **JSONL is the object pipeline** — commands emit records, jq is the engine
- **Cmdlet suite**: `bu where-object`, `bu select-object`, `bu sort-object`, `bu distinct-object`, `bu format-table`, `bu out-default`, ...
- **`bu query-object`** — SQL in one command: `where`, `group-by`, `agg`, `having`, `select`, `distinct`, `order-by`, `first` in any order
- **Out-Default**: tables on a terminal, JSONL when piped — automatically
- **Pipeline-aware completion**: `bu get-command | bu select-object <TAB>` suggests the producer's fields
- See [Structured Output](./structured_output.md)

### 📦 Module system
- `BU_MODULE_PATH` — colon-separated list of module scripts
- `bu new-module --name myapp` — scaffold a module with activate / module script / preinit callback / commands directory
- `bu get-module` — inspect loaded modules with name, version, and path
- Module preinit callbacks register commands, keybindings, aliases, and completion specs

### 📝 Argument parsing that writes your completions
- `bu_parse_multiselect` — named flags with `-h|--help)# _FLAG` syntax
- `bu_parse_positional` — positional args with `--enum`, `--hint`, `--as-if` completion
- Single definition drives both runtime parsing AND autocomplete generation — no duplication

### 🔒 Safety
- RAII-style scope stack (`bu_scope_push_function` / `bu_scope_pop_function`) ensures cleanups run
- Custom `source` with `--__bu-once` prevents redundant re-sourcing
- `bu_exit_handler_setup` catches unexpected exits

### 🔌 Fig spec integration
BashTab can use [Fig completion specs](https://github.com/withfig/autocomplete) as a fallback when no native bash completion exists (715+ CLIs).

**Setup** (handled automatically by `./setup`):
```sh
git submodule update --init fig_specs
cd fig_specs && pnpm install && pnpm build && node ../fig_convert_to_json.mjs
```

**What you get:**
- `bu get-fig-status` — see which commands on your PATH are covered
- `bu get-fig-status --useful` — commands on PATH that lack bash completions
- Automatic fallback: pressing `<TAB>` on an unknown command checks the Fig specs

### 🎯 Everything is a script
Every built-in command — `bu new-command`, `bu import-environment`, `bu get-command` — is a Bash script generated from the same template you use. The framework eats its own dogfood.

## Not in scope

BashTab is **not**:
- A package manager (no `import`/`load` — use `source` and `BU_MODULE_PATH`)
- A YAML/TOML-to-Bash compiler (we stay in Bash)
- A POSIX-sh framework (requires Bash 4+, uses associative arrays, `coproc`, `mapfile`)

