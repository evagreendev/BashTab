# Line Transforms (design proposal)

> **Status:** design proposal — **not yet implemented**. This document
> captures the agreed spec for a generic, reversible command-line rewrite
> feature that replaces the removed `__bu_bind_toggle_gdb` toggle.

## 1. Model

A **transform** is a rewrite rule `match → replace` over the current
`READLINE_LINE`. Both directions are just transforms — "unwrap" is a
transform whose `match` recognizes an already-wrapped line. Everything is
`line → line`, so there is no toggle and no detection heuristic, and the
`sudo sudo apt update` ambiguity does not arise: the user explicitly picks
which transform to apply.

## 2. Placeholder vocabulary (v1)

| Placeholder (aliases) | Kind | Meaning |
|---|---|---|
| `{line}` (`{all}`) | raw rest | the whole line, verbatim (spacing and quoting preserved) |
| `{prog}` | token | the command word (first whitespace-delimited word) |
| `{args}` (`{@}`, `{...}`) | token rest | all words after the first |

- `{line}` is **lossless**; `{prog}` and `{args}` are **lossy**
  (tokenization collapses whitespace and drops quoting).
- On the **match** side, placeholders capture. On the **replace** side, they
  emit the captured value — or, for `{prog}`/`{args}`, a **projection** of a
  captured `{line}` (first word / rest words).

## 3. Rule shape

```bash
bu_preinit_register_line_transform <name> \
    --match    'sudo {line}' \
    --replace  '{line}' \
    --description 'Strip a leading sudo'
```

Both templates are literals plus placeholders. A **match** template is one
of three forms:

- **string mode**: `P {line} S` — `{line}` is the only placeholder; matches
  if the line starts with `P` and ends with `S` (raw prefix/suffix).
- **token mode**: a whitespace-separated sequence of literal words, `{prog}`,
  and a trailing `{args}` — matched against word-split tokens.
- **mixed**: `token-seq + {line}` (e.g. `gdb {prog} --args {line}`) — token
  match the front, then `{line}` captures the raw remainder after the last
  matched literal.

A **replace** template is a free mix of literals and the captured/projected
placeholders.

## 4. Matching semantics

- Tokenization for `{prog}`/`{args}` uses `read -r -a`-style splitting (IFS
  whitespace), matching the behavior of the old gdb toggle. **Accepted for
  v1** — token-mode round-trips normalize whitespace and drop quoting.
- `{line}` always captures raw text, byte-for-byte.
- In **mixed** mode, `{line}` captures the verbatim remainder after the
  matched token sequence; exact whitespace boundary follows the same
  normalization and is an implementation detail.

## 5. Validity checker

Reject a registration if any rule fails:

1. **Whitelist** — unknown `{...}` tokens are a hard error (catches typos
   such as `{lnie}`).
2. **Arity** — at most one *rest* placeholder per side (`{line}`/`{all}`
   **or** `{args}`/`{@}`/`{...}`, not both); `{prog}` at most once per side.
3. **Position** — a rest placeholder must be trailing on its side; nothing
   may follow it.
4. **Unquoted** — no placeholder may sit inside single or double quotes in a
   template.
5. **Replace references** — every replace-side placeholder must be available
   from the match side:
   - `{line}` requires `{line}`/`{all}` captured.
   - `{prog}` requires `{prog}` captured, **or** `{line}`/`{all}` captured
     (→ first-word projection).
   - `{args}` requires `{args}` captured, **or** `{line}`/`{all}` captured
     (→ rest-words projection).

Rules 2–3 make every match decidable; rule 5 makes every replace
well-formed.

## 6. Auto-inverse

After validating a rule, swap `match ↔ replace` and re-run the checker. If
the swapped pair is also valid, register the inverse automatically as its
own transform:

- `wrap-<x>` → `unwrap-<x>`; any other name → `<name>-inverse`.
- Stamped `derived=true` in the registry; an **explicit** registration with
  that name overrides the derived one.

**Exactness**: an inverse whose replace is `{line}` is lossless (round-trips
byte-for-byte). An inverse that rebuilds from `{prog}`/`{args}` only is
lossy (whitespace-normalized). The `derived` property records which.

## 7. Examples

| name | match | replace | auto-inverse | exact? |
|---|---|---|---|---|
| `wrap-sudo` | `{line}` | `sudo {line}` | `unwrap-sudo`: `sudo {line}` → `{line}` | yes |
| `wrap-timeout` | `{line}` | `timeout 30s {line}` | `unwrap-timeout` | yes |
| `wrap-gdb` | `{line}` | `gdb {prog} --args {line}` | `unwrap-gdb`: `gdb {prog} --args {line}` → `{line}` | yes |
| `drop-log-level` | `LOG=INFO {args}` | `{args}` | `LOG=INFO {line}` → … → `{line}` | lossy |
| `wrap-quoted` | `{line}` | `bash -c '{line}'` | — (rejected: `{line}` inside quotes) | — |

`wrap-gdb` on `apt update` → `gdb apt --args apt update`; `unwrap-gdb` on
that → `apt update` — the original gdb behavior, but registered,
attributable, and listed.

## 8. Registry & provenance

Mirrors the key-binding registry:

```bash
declare -A -g BU_LINE_TRANSFORM_PROPERTIES=()
# [name,match] [name,replace] [name,description] [name,module] [name,derived]
```

- `bu_preinit_register_line_transform` stamps `[name,module]=$BU_CURRENT_MODULE`
  (falling back to `bu` for core).
- `bu get-transform` lists transforms via the JSONL pipeline with a
  `Module` column (same pattern as `bu get-command`).

## 9. Selector (opt-in)

- Chord: `bu_preinit_register_user_defined_key_binding '\et' '__bu_bind_transform_selector' "Pick a command-line transform"`
  — **not** a new default binding.
- Opens fzf over the registry. Each row shows `name + description`; the
  **preview pane** shows the current line transformed (or `no match`).
  Rows whose `match` does not hit are dimmed.
- Enter applies the chosen transform to `READLINE_LINE`/`READLINE_POINT`
  (single-apply, v1).
- Reuses existing machinery (`__bu_fzf_compute_dimensions`, the fzf
  completion impl's preview pattern).

## 10. Scope

**v1 (this spec):** `{line}` / `{prog}` / `{args}`, the validity checker,
auto-derived inverses, opt-in selector, single-apply.

**Non-goals / v2 candidates:** positional placeholders (`{1}`, `{2}`),
multi-select composition in the selector, direct per-transform key bindings
as a first-class registry concept (embedders can already register a key
binding to `__bu_bind_transform <name>`), whitespace-preserving token mode.
