---
layout: page
title: Technical Reference
permalink: /technical-reference/
nav-order: 5
---

## Using bu as a scripting dependency

The recommended way to use BashTab in your project is via the module system.

```sh
# 1. Add BashTab as a git submodule
git submodule add https://github.com/sunjc826/BashTab.git deps/bash-tab

# 2. Scaffold your module
source deps/bash-tab/activate
bu new-module --name myproject

# 3. Edit myproject/myproject_bu_preinit.sh, then activate
source ./myproject/activate
```

See the [Workflow Guide](how-to-02-BashTab-workflow) for a complete walkthrough.

### Legacy (manual registration)

The following variables and functions are used by libraries invoking BashTab to change its behavior at initialization time.

### Initialization variables
Bash variables are all strings/arrays of strings/maps of strings, alongside some variable attributes (e.g. number `-i`, readonly `-r` etc.) but we can interpret them differently.
These variables are "declared" (really, it's for bash-langugage server to give hints when hovering over them) in [bu_user_defined_decl.sh][bu_user_defined_decl].

The customizable variables all have the `BU_USER_DEFINED_` prefix.

Let us define the following conventional variable "types":

| Type | Description | Example |
|---|---|---|
| `Function` | The variable name refers to a shell function. | `bu_init() { ... }` |
| `AbsPath[A]` | Absolute path. `A` is an optional annotation describing the expected file type (for example, `ExecutableScript` or `SourceableScript`). |  |
| `ExecutableScript` | Annotation for `AbsPath` indicating the file is an executable script. | `/usr/local/bin/my-script` has type `AbsPath[ExecutableScript]` |
| `SourceableScript` | Annotation for `AbsPath` indicating the file is intended to be sourced. | `./bu_entrypoint.sh` has type `RelPath[SourceableScript]` |
| `RelPath[A]` | Relative path. `A` is an optional annotation like with `AbsPath`. | `scripts/myscript.sh` |
| `Path[A]` | Either `AbsPath[A]` or `RelPath[A]`. | `./lib/core/bu_core_base.sh` |
| `Int` | Integer value. | `42` |
| `Ref[T]` | A nameref to `T`, where `T` is some parameterized type. | `declare -n ref=executable_script_path_name` has type `Ref[Path[ExecutableScript]]` |
| `Array[T]` | Bash indexed array whose elements are of type `T`. | `BU_FOO=(one two three)` has type `Array[String]` <br> `BU_BAR=(1 2 3)` has type `Array[Int]` |
| `Map[K, V]` | Bash associative array mapping keys of type `K` to values of type `V`. | `declare -A m=([1]=one)` has type `Map[Int, String]` |
| `T1 \| T2` | Union Type of `T1` and `T2` | |

Variable list

| Variable | Type | Description |
|---|---|---|
| `BU_USER_DEFINED_STATIC_CONFIGS` | `Array[ Function \| Path[SourceableScript] ]` | Static user-defined configuration callback scripts/functions. These are sourced once during initialization. |
| `BU_USER_DEFINED_DYNAMIC_CONFIGS` | `Array[ Function \| Path[SourceableScript] ]` | Dynamic user-defined configuration callback scripts/functions. These are sourced every time the shell sources user-defined configs. |
| `BU_USER_DEFINED_STATIC_PRE_INIT_ENTRYPOINT_CALLBACKS` | `Array[ Function \| Path[SourceableScript] ]` | Static user-defined pre-initialization callback scripts/functions. These are sourced once before shell initialization. |
| `BU_USER_DEFINED_DYNAMIC_POST_ENTRYPOINT_CALLBACKS` | `Array[ Function \| Path[SourceableScript] ]` | Dynamic user-defined post-initialization callback scripts/functions. These are sourced after shell initialization. |
| `BU_USER_DEFINED_STATIC_POST_ENTRYPOINT_CALLBACKS` | `Array[ Function \| Path[SourceableScript] ]` | Static user-defined post-initialization callback scripts/functions. These are sourced once after shell initialization. |
| `BU_USER_DEFINED_DYNAMIC_POST_ENTRYPOINT_CALLBACKS` | `Array[ Function \| Path[SourceableScript] ]` | Dynamic user-defined post-initialization callback scripts/functions. These are sourced after shell initialization. |
| `BU_USER_DEFINED_COMPLETION_COMMAND_TO_KEY_CONVERSIONS` | `Array[Function]` | User-defined command-to-key conversion functions. These functions can customize how commands are converted to completion keys. |
| `BU_USER_DEFINED_AUTOCOMPLETE_HELPERS` | `Array[Function]` | User-defined autocomplete helper functions. These functions provide custom lazy autocompletion behavior. |
| `BU_USER_DEFINED_CLI_COMMAND_NAME` | `Function` | A custom command line name for `bu`. |

### Module registry

Modules can self-identify via `__bu_module_register`:

```sh
__bu_module_register "modname" "0.1.0" "/path/to/modname_bu_preinit.sh"
```

This populates:

| Variable | Type | Description |
|---|---|---|
| `BU_MODULE_REGISTRY` | `Map[String, String]` | `name → "version:preinit_path"`. Available in current shell. |
| `BU_MODULE_LIST` | `String` (exported) | `"name:version:path;..."`. Survives subshells for `bu get-module`. |

`bu get-module` reads `BU_MODULE_LIST` to display loaded modules with name, version, and path. Legacy modules (without `__bu_module_register`) still work but won't appear in the listing.

### Initialization callable functions
Another point of customization are the pre-init functions. They are found in [bu_core_preinit.sh][bu_core_preinit]. They all have the `bu_preinit_` prefix.

- `bu_preinit_register_user_defined_key_binding`:
  - Description: Register a key binding for interactive shells. Values are stored in `BU_KEY_BINDINGS` and later applied via `bind -x`.
  - Params: `$1` = key sequence (e.g. `\ee`), `$2` = command/function to invoke.
  - Example: `bu_preinit_register_user_defined_key_binding '\em' my_custom_edit`

- `bu_preinit_register_user_defined_completion_func`:
  - Description: Register a completion function for a specific command. Mappings are stored in `BU_AUTOCOMPLETE_COMPLETION_FUNCS` and used to call `complete -F`.
  - Params: `$1` = command name, `$2` = completion function name.
  - Example: `bu_preinit_register_user_defined_completion_func mycmd __mycmd_completion`

- `bu_preinit_register_user_defined_subcommand_dir`:
  - Description: Register a directory containing subcommand scripts. Optionally provide a conversion function to transform file names to `verb-noun` command names.
  - Params: `$1` = directory path, `...` = optional conversion function and args.
  - Example: `bu_preinit_register_user_defined_subcommand_dir ~/my-commands bu_convert_file_to_command_namespace prefix`

- `bu_preinit_register_user_defined_subcommand_file`:
  - Description: Register a single script file as a `bu` subcommand.
  - Params: `$1` = file path, `$2` (optional) = command name (derived from filename if omitted), `$3` (optional) = type (`function`, `execute`, `source`).
  - Example: `bu_preinit_register_user_defined_subcommand_file ~/scripts/get-status.sh get-status execute`

- `bu_preinit_register_user_defined_subcommand_function`:
  - Description: Register an in-shell function as a `bu` subcommand.
  - Params: `$1` = function name, `$2` (optional) = command name, `$3` (optional) = type.
  - Example: `bu_preinit_register_user_defined_subcommand_function my_helper_func my-helper function`

- `bu_preinit_register_new_alias`:
  - Description: Create a `bu` alias that expands a positional-style invocation into a named-argument command. Alias specs use `{}` for a single positional, `{...}` for remaining input, and `{?}` for optional remaining input.
  - Params: `$1` = alias name, `$2..` = alias spec (see `bu_preinit_register_new_alias` for syntax rules).
  - Example: `bu_preinit_register_new_alias gc get-command --namespace {} {?} --verb {} {?} --noun {} {...}`


## Development & Contributing

### Code structure
The core library is in [core][core]
- [bu_core_base.sh][bu_core_base] provides the core library functions for the framework
- [bu_core_autocomplete.sh][bu_core_autocomplete] provides the autocompletion functionality for the `bu` command and the scripts it invokes.

There are library functions that are not used by the core scripting framework, but are nonetheless useful in writing your own scripts.
- [bu_core_tmux.sh][bu_core_tmux] provides imperative utilities (`bu_spawn`) for orchestrating jobs across tmux panes.

### Running Tests

BashTab uses the [BATS (Bash Automated Testing System)](https://github.com/bats-core/bats-core) framework for unit testing.

```sh
git submodule update --init
source ./bu_test_entrypoint.sh
bats ./test/parse_bash_test.bats    # hand-written parser tests (54 tests)
bats ./test/ts_test.bats            # tree-sitter daemon tests (49 tests)
bats ./test/fzf_dims_test.bats      # fzf dimension calculation tests (14 tests)
bats ./test/out_test.bats           # structured output tests (38 tests)
```

### Tree-sitter daemon

Located at `lib/bin/bu_ts_daemon.js`. The bash wrapper `lib/core/bu_core_ts.sh` manages a `coproc` node process that accepts `CURSOR:LINE` input and returns JSON CST with:

| Field | Description |
|---|---|
| `cmdName` | Command name at cursor |
| `cmdWords` | Space-separated command words (unit separator delimited) |
| `pipeBefore` / `pipeAfter` | Text before/after the last pipe separator |
| `cursor.replaceStart/End/Text` | Range-based replacement (LSP TextEdit style) |
| `cursor.completeKind` | `command`, `dollar_word`, `dollar_brace` |

Toggle with `BU_AUTOCOMPLETE_USE_TREE_SITTER=true`.

### fzf autocomplete display

The `__bu_fzf_compute_dimensions` function handles dropdown positioning (tested across 40–200 column terminals). Metadata formatting is shared between the legacy and tree-sitter autocomplete paths, with:
- Inline hints: type tags + sizes in fzf `--with-nth` fields
- Preview panel: 40-char side window via `--preview` when metadata overflows

### Structured output (JSONL pipeline)

Inspired by PowerShell's object pipeline: **JSONL (one JSON object per line) is the object stream**. Commands produce records and a sink formatter decides presentation at the end of the pipeline. jq is the backend throughout. Implemented in [bu_core_out.sh](../lib/core/bu_core_out.sh).

**Layers**

| Layer | Functions | Model |
|---|---|---|
| Recordifiers (raw → JSONL) | `bu_out_record k=v` / `k:=v` (typed), `bu_out_from_tsv --columns`, `bu_out_from_lines --column` | per-record fork, or one jq per stream |
| Transforms (JSONL → JSONL) | `bu_out_where '<jq expr>'`, `bu_out_select a,b=version`, `bu_out_sort_by key [--desc]` | streaming (except sort, which buffers) |
| Sinks (JSONL → display) | `bu_format_table [--stream] [--colors]`, `bu_format_list`, `bu_format_json`, `bu_format_jsonl`, `bu_format_tsv` | see buffering notes below |
| Dispatcher | `bu_out [--format auto\|table\|list\|json\|jsonl\|tsv]` | Out-Default analog |

**Format resolution** (`bu_out` / `--format auto`): explicit flag → `BU_OUTPUT_FORMAT` → terminal detection (table on a TTY, JSONL when piped). So `bu get-module` prints a table interactively and `bu get-module | jq ...` just works.

**Command integration pattern** — zero forks in the record loop, exactly two jq processes:

```bash
{
    for entry in "${entries[@]}"; do
        printf '%s\t%s\t%s\n' "$name" "$version" "$path"
    done
} | bu_out_from_tsv --columns name,version,path | bu_out --format "$format"
```

TSV mode requires values without tabs/newlines; use `bu_out_record` per record for arbitrary strings.

**Sink buffering**: `table` (auto-width) and `json` buffer all input; `table --stream` emits immediately with proportional widths (requires `--columns`); `list`, `tsv`, `jsonl` stream with O(1) latency.

**Column labels**: `--columns name:Module,version` renames display headers in table/list; lookups and `--colors name=green` still use the record key. tsv recordifiers strip labels.

**Cmdlet commands** (usable in any pipeline):

| PowerShell | bu command |
|---|---|
| `[PSCustomObject]@{...}` | `bu new-record k=v ...` |
| ConvertFrom-Csv | `bu convert-from-tsv --columns`, `bu convert-from-lines --column` |
| Where-Object | `bu where-object '<jq expr>'` |
| Select-Object | `bu select-object name,ver=version` |
| Sort-Object | `bu sort-object key [--desc]` |
| Format-Table / Format-List | `bu format-table`, `bu format-list` |
| ConvertTo-Json | `bu convert-to-json`, `bu convert-to-jsonl`, `bu convert-to-tsv` |
| Out-Default | `bu out-default` |

```bash
bu get-command | bu format-table
bu get-command | bu where-object '.verb == "get"' | bu sort-object name | bu out-default
```

**Cmdlets end at Out-Default**: every cmdlet pipes its records through `bu_out`, so a transform at the end of a terminal pipeline renders a table automatically — no explicit formatter needed. Intermediate stages see a pipe and stay JSONL. The core functions (`bu_out_select` etc.) remain pure JSONL for scripting; only the cmdlets append Out-Default.

```bash
bu get-command | bu select-object name,verb        # table on a terminal
bu get-command | bu select-object name,verb | jq . # JSONL when piped
```

**`bu query-object`** composes the transforms into one SQL-style command. Clause keywords work bare or dashed (`select` / `--select`), in any order; execution always follows SQL logical order: WHERE → SELECT → ORDER BY → FIRST. `--where` uses source field names (repeatable, ANDed), `--order-by` uses output field names (SELECT aliases, like SQL), `--first` is LIMIT. Clause values get pipeline field completion.

```bash
bu get-command | bu query-object where '.type == "source"' select name,verb order-by verb
bu get-command | bu query-object order-by name desc first 5
bu get-command | bu query-object select name,ver=version order-by ver   # order by alias
```

**Multi-word verbs**: command name parsing honors `BU_MULTI_WORD_VERBS` (default: `convert-to`, `convert-from`), so `bu-convert-to-jsonl.sh` registers verb=`convert-to`, noun=`jsonl`. Longest match wins; extend the array from user-defined configs for custom multi-word verbs.

### Pipeline-aware field completion

PowerShell-style: when completing after a pipe, `bu select-object`, `bu where-object`, `bu sort-object` and the `--columns` flags of the sink cmdlets suggest the **record fields of the pipeline producer**.

```
bu get-command | bu select-object <TAB>   # name verb noun namespace type
bu get-command | bu select-object name,<TAB>   # comma-aware: offers the rest
bu get-command | bu where-object <TAB>    # .name .verb .noun .namespace .type
```

Field sources, in order:

1. **Static registry** `BU_OUT_PRODUCER_FIELDS` (assoc: producer prefix → fields).
   Longest prefix match, so producer flags and later pipeline stages don't break
   the match. Seeded with the builtins; register your own producers from a module
   preinit script:
   ```bash
   bu_register_output_fields "bu get-pokemon" name id type hp attack
   ```
2. **Opt-in probing**: with `BU_OUT_PROBE_PIPELINE=true` and the producer head in
   `BU_OUT_PROBE_COMMANDS`, the producer is executed as typed and the keys of its
   first JSONL record become the candidates (piped bu commands auto-emit JSONL).
   Off by default — probing runs user-typed text, so both switches are explicit.

Producer text comes from the completion bindings via dynamic scope:
`command_line_front_before_pipe` (legacy parser), `pipe_before` (tree-sitter),
with a `COMP_WORDS` pipe-walk as fallback. Inaccurate by design for exotic
pipelines — for simple cases it just works.

### Code Documentation Standards

This project follows a consistent documentation format for functions and variables, designed to work with [bash-language-server](https://github.com/bash-lsp/bash-language-server).

#### Function Documentation Format

Functions should be documented with the following format:

```sh
# ```
# *Description*
# Short description of function
#
# *Params*:
# - `$1`: Description of first parameter
# - `$2`: Description of second parameter
#
# *Returns*:
# - `$BU_RET`: Description of return value
#
# *Example*:
# ```bash
# function_name "arg1" "arg2"
# ```
#
# *Notes*:
# - Important note 1
# - Important note 2
# ```
```

The outer triple backticks allow bash-language-server to properly parse the markdown documentation inside the comments. How it works is that bash-language-server defaults to wrapping comment blocks in a `` ``` `` block, thus the top and bottom triple backticks close up the txt block so we can add arbitrary markdown in between.

#### Variable Naming Conventions

- **Global Variables**: Prefix with `BU_` to namespace them within BashTab (e.g., `BU_VERSION`, `BU_CONFIG_PATH`)
- **Functions**: Prefix with `bu_` to namespace them (e.g., `bu_init`, `bu_parse_args`)
- **Return Values**: 
  - Use `BU_RET` to return strings and non-associative arrays. The value can be either scalar or array depending on the function's purpose
  - Use `BU_RET_MAP` to return associative arrays.
- **User-Defined Variables**: Prefix with `BU_USER_DEFINED_` for variables that are expected to be defined externally by users

### Building a Single-File Distribution

To consolidate the entire BashTab library into a single file for easier distribution or embedding:

```sh
source ./activate --__bu-inline ./inline.sh
```

This generates an `inline.sh` file containing the complete BashTab library.
`--__bu-inline` makes certain assumptions about where source statements are invoked, so this might break at some points.


{% capture github_base %}{{ site.github.repository_url }}/blob/{{ site.github.build_revision }}/{% endcapture %}
{% capture links %}

[commands]: ../commands/
[bu-import-environment]: ../commands/bu-import-environment.sh
[bu-get-command]: ../commands/bu-get-command.sh
[bu-new-command]: ../commands/bu-new-command.sh
[bu-run-example]: ../examples/commands/bu-run-example.sh
[bu_user_defined_decl]: ../bu_user_defined_decl.sh
[bu_core_preinit]: ../lib/core/bu_core_preinit.sh
[core]: ../lib/core/
[bu_core_base]: ../lib/core/bu_core_base.sh
[bu_core_autocomplete]: ../lib/core/bu_core_autocomplete.sh
[bu_core_tmux]: ../lib/core/bu_core_tmux.sh

{% endcapture %}
<!-- https://shopify.github.io/liquid/filters/replace_first/ -->
<!-- https://stackoverflow.com/questions/27694610/how-can-i-split-a-string-by-newline-in-shopify -->
{% assign links_list = links | newline_to_br | split: '<br />' %}
{% for link in links_list %}
{{ link | replace_first: "../", github_base }}
{% endfor %}
