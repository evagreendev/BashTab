---
layout: page
title: Context Variables
permalink: /context-variables/
nav_order: 7
---

# Context Variables (origin tracking & consumption logging)

Commands take defaults from **ambient "context" variables** — environment /
configuration variables set by the embedding project, e.g. a theme colour
exported from a site config file, or an app-wide setting sourced at shell
init.  Two questions were previously unanswerable:

1. **Which** context variables does a command actually consume?
2. **Where** did each variable's value come from?

`lib/core/bu_core_context.sh` answers both.  It provides two facilities —
a **write side** that records where ambient variables are assigned, and a
**read side** that logs when a command consumes one — plus the
`bu get-context-usage` query builtin to inspect the log.

```bash
# Answer both questions in one pipeline:
$ bu get-context-usage | bu query-object where var -eq MY_APP_COLO select command distinct
```

---

## Write side — origin tracking

```bash
bu_var_origin_enable [--reset] [--prefix-regex RE]   # arm
source ./config/my_site_vars.sh                       # the window
bu_var_origin_disable                                 # disarm
```

While armed, a `DEBUG` trap (`+ set -o functrace`) records, for every
executed simple command matching `^(NAME)=` (NAME matching the prefix regex,
default `[A-Z_][A-Z0-9_]*` — CAPS names only), the assignment's location:

```
BU_VARIABLE_ORIGIN[NAME]="file:line"
```

Last write wins.  The map is a plain associative array you can inspect:

```bash
bu_var_origin_enable --reset
source ./config/site.sh
bu_var_origin_disable
declare -p BU_VARIABLE_ORIGIN
# declare -A BU_VARIABLE_ORIGIN=([MY_APP_COLO]="/abs/path/config/site.sh:12" ...)
```

Properties:

- **Nothing is armed by default** anywhere in core.  The steady-state cost is
  zero; embedders choose the windows they care about (e.g. around sourcing
  their configuration chain).
- **Windows accumulate** into the map across enable/disable cycles unless
  `--reset` is given.
- **Composable with other `DEBUG` users**: the pre-existing `DEBUG` trap and
  the `functrace` flag are saved on enable and restored on disable.
- **`--reset`** clears the map first and applies even when already armed.
  Enable-while-armed is otherwise a no-op (it never nests).
- **`--prefix-regex RE`** narrows which names are tracked.  `RE` is a POSIX
  ERE fragment matching the variable name.
- Recorded line numbers are exact; relative `BASH_SOURCE` is absolutized
  against `PWD`.

---

## Read side — consumption logging

Two helpers announce that a command consumed a context variable.  Each call
emits **one compact stderr line** at read time and appends **one JSONL
record** to `$BU_OUT_DIR/context/<YYYY-MM-DD>.jsonl`:

```
{"ts":1788195734,"command":"bu-get-version","var":"MY_APP_COLO","value":"blue","local":"colour","source":"context","origin":"/abs/path/config/site.sh:12"}
```

| Field    | Meaning                                                                 |
|----------|-------------------------------------------------------------------------|
| `ts`     | Epoch seconds at read time                                              |
| `command`| Consuming script basename, `.sh` stripped                               |
| `var`    | The ambient context variable consulted                                  |
| `value`  | The ambient variable's value at read time                               |
| `local`  | The local it mapped to (empty for `bu_context_use`)                     |
| `source` | `context` (used), `flag` (overridden), or `read` (unconditional)        |
| `origin` | `file:line` of the last tracked assignment, when `BU_VARIABLE_ORIGIN` knows it |

### Form 1 (preferred) — `bu_context_default`

```bash
bu_context_default VARNAME CONTEXT_VAR
```

This is **the** idiomatic replacement for the flag-default boilerplate
`[[ -n "$x" ]] || x=${CONTEXT_VAR:-}`:

```bash
# before
local colour=
[[ -n "$colour" ]] || colour=${MY_APP_COLO:-}

# after
local colour=
bu_context_default colour MY_APP_COLO
```

- If `VARNAME` is already non-empty (an explicit argument won), it is kept
  and the call logs `source=flag`.  Logging this case is deliberate: it
  answers *"would this command have used `CONTEXT_VAR`?"*.
- Otherwise `VARNAME` is assigned from `CONTEXT_VAR` (via nameref; it may
  remain empty when the variable is unset — still logged, because
  *"wanted it, wasn't set"* is signal) and the call logs `source=context`.

### Form 2 — `bu_context_use`

```bash
bu_context_use CONTEXT_VAR
```

An unconditional read; the value is returned in `BU_RET[0]` and logged with
`source=read`.

**Preference ordering** (form 1 first):

1. Refactor the call site to `bu_context_default` — make the input
   argument-injectable.
2. If that doesn't fit, consider whether the variable is a genuine
   contextual input worth logging.  Framework/plumbing paths are **not**.

### Guarantees

- The stderr line is compact and single-line; the origin suffix
  `(file:line)` is appended only when `BU_VARIABLE_ORIGIN[CONTEXT_VAR]` is
  populated.  The flag-won case reads
  `[ctx] local=value <- flag (CONTEXT_VAR overridden)`.
- JSON escaping is pure bash (backslash, double quote; newlines/tabs
  flattened, CR stripped) — no subprocess per record.
- No dedup bookkeeping: repeated reads log repeatedly.  That's acceptable
  and cheap.
- Helpers **never fail the caller**: an unwritable record path degrades
  silently to stderr-only; autocomplete context suppresses both outputs
  entirely; everything is `set -e` / `set -u` safe.

---

## Query builtin

```bash
bu get-context-usage [--format auto|table|list|json|jsonl|tsv] [--columns ...]
```

Concatenates `$BU_OUT_DIR/context/*.jsonl` (daily files sort lexically,
which is chronologically) into a single JSONL stream.  No records → empty
success.  Compose a census with `bu query-object`:

```bash
# Which commands ever consult MY_APP_COLO?
bu get-context-usage | bu query-object where var -eq MY_APP_COLO select command distinct

# Every consumption, with provenance:
bu get-context-usage | bu query-object select command,var,value,source,origin
```

---

## Putting it together

```bash
# In an embedder's activate script: track where site config is set,
# then let commands log what they consume.
bu_var_origin_enable
source ./site/*.sh        # or your own config chain
bu_var_origin_disable

# Commands adopt form 1:
local colour=
bu_context_default colour MY_APP_COLO
```
