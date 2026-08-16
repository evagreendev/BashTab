# Releasing BashTab

BashTab is released with **datetime-based (CalVer) tags**, not arbitrary
semver. The tag is never chosen by hand — it is derived from the current UTC
date plus any same-day releases that already exist.

## Why not semver?

BashTab is a framework people install by `git clone` + `source activate`.
There is no stable public API version to bump, and the old `v1.0.0` /
`v1.1.0` tags were picked arbitrarily and immediately went stale (70 commits
shipped after `v1.1.0` before the next tag). A date tag answers the only
question that actually matters for a rolling checkout — *"how old is this?"*
— and it removes the version-number bikeshed entirely.

## Tag scheme

| Tag              | Meaning                                    |
|------------------|--------------------------------------------|
| `v2026.08.15`    | first release on 2026-08-15 (UTC)          |
| `v2026.08.15.1`  | second release that same UTC day           |
| `v2026.08.15.2`  | third release that same UTC day            |

- **Date is UTC**, zero-padded (`YYYY.MM.DD`).
- The trailing `.N` only appears when more than one release happens in a
  UTC day; `N` is `(highest existing suffix) + 1`. This is max-based, so a
  manually-deleted intermediate tag can never cause a collision or a
  backward bump.
- Tags are **annotated** and carry a short commit summary in the message.
- Tags are **monotonic and sortable**: `sort -V` and
  `git tag --sort=v:refname` both order them chronologically.

## Cutting a release

```sh
./release.sh --dry-run   # preview the next tag + what changed
./release.sh             # cut + push the tag, open a GitHub Release
```

The script:

1. Verifies a clean worktree on `main` (skip with `--force`).
2. Aborts with "nothing to release" if HEAD is already tagged.
3. Computes the next tag from the UTC date (and same-day counter).
4. Creates an annotated tag whose message lists the commits since the
   previous tag.
5. Pushes the branch + tag, and creates a GitHub Release with
   auto-generated notes (requires `gh`; skipped if absent or `--no-gh`).

Options: `--yes` (non-interactive), `--no-push`, `--no-gh`, `--force`,
`--dry-run`.

### From CI

`.github/workflows/release.yml` runs the same script via
**workflow_dispatch** (manual "Run workflow" button). To release
automatically on every push to `main`, uncomment the `push` trigger in that
file.

## How the version is surfaced at runtime

At activation, `bu_entrypoint.sh` computes:

- `BU_VERSION` — `git describe --tags --always --dirty`, e.g.
  `v2026.08.15-3-g1f4ae9c` (or `...-dirty` with uncommitted changes).
- `BU_VERSION_TAG` — the nearest release tag.
- `BU_REPO_SHA1` — the full commit hash (unchanged, used by the
  "different version" warning).

`bu get-version` prints these as a structured record:

```sh
bu get-version                 # table on a terminal, JSONL when piped
bu get-version --format json
bu get-version --columns tag   # just the release tag
```

Because the version is `git describe`, a checkout immediately reveals both
*which release* it is on and *how far ahead/behind* it is — no version file
to keep in sync.

## Migrating from the old tags

No action required. The old `v1.0.0` / `v1.1.0` tags remain in history and
`git describe` will keep working across them (e.g.
`v1.1.0-70-g1f4ae9c`). The first CalVer tag simply becomes the new nearest
tag. To clean up, delete the old tags on the remote:

```sh
git push origin --delete v1.0.0 v1.1.0   # then delete locally with `git tag -d`
```

## Notes

- **`package.json` `version` is unused** by BashTab. It exists only for the
  Node/tree-sitter dev tooling and is intentionally not managed by the
  release script (a 4-component CalVer like `2026.08.15.1` is not valid
  semver anyway). Consider removing the field.
- **UTC** is authoritative. Someone releasing near midnight local time may
  see "yesterday's" or "tomorrow's" date — that is expected and keeps tags
  globally unambiguous.
