# gitshelf — the canonical BashTab demo module

`gitshelf` is a tiny "repo shelf": it tracks a set of local git repositories in
one JSON config file and reports on them as a JSONL stream. The domain is
deliberately boring — every design decision here exists to showcase the
BashTab **module system**, not the problem.

The same checkout serves two roles with zero changes:

| Role     | Entrypoint               | Sets `BU_TOP_LEVEL_MODULE` | Calls `bu_mark_load_complete` |
|----------|--------------------------|----------------------------|-------------------------------|
| **Binary** | `activate`              | yes — `gitshelf`           | yes                            |
| **Library** | `gitshelf_bu_module.sh` | no — inherits the host's   | no — the host handles caching  |

## Standalone use (binary mode)

```sh
source examples/gitshelf/activate
```

This gives you a `shelf` CLI in a fresh shell:

```sh
shelf get-repo                    # one JSONL record per configured repo
shelf get-repo --format table     # human table on a terminal
shelf get-repo --format jsonl     # force JSONL even on a terminal
```

Because `get-repo` is a JSONL **producer**, it composes with the pipeline:

```sh
shelf get-repo | shelf query-object where dirty -eq true select name,branch
shelf get-repo | shelf where dirty -eq true            # `where` is an alias
```

Mutate the config (writes go through jq to a temp file, then `mv`):

```sh
shelf add-repo --path ~/src/new-thing --tag shell
shelf remove-repo --name new-thing
```

Fetch upstreams for one repo or all:

```sh
shelf sync-repo --dry-run
shelf sync-repo --name bashtab
```

## Library use (host project: devbox)

`examples/devbox/` is a tiny host that consumes gitshelf as a library:

```sh
source examples/devbox/activate
```

Now `devbox` exposes **its own** commands and **gitshelf's** under one command
registry, one cache key, one help system:

```sh
devbox get-repo                  # gitshelf's command, via devbox's CLI name
devbox get-env                   # devbox's own command, side by side
bu get-module                    # lists BOTH modules with name/version/path
```

```sh
devbox get-module --format table
```

## Re-activation matrix

What happens when you source gitshelf's `activate` in different shells:

| Starting shell state                              | Result |
|---------------------------------------------------|--------|
| Fresh shell (no BashTab loaded)                   | Full activation: `shelf` becomes the CLI, `BU_TOP_LEVEL_MODULE=gitshelf`, cache saved |
| Already a **devbox** shell (gitshelf already in `BU_MODULE_LIST`) | **INFO** no-op: "gitshelf already active under devbox — commands available via 'devbox'"; nothing changes |
| Already some **other** BashTab shell (gitshelf not registered) | **WARN** no-op: tells you to start a fresh shell or add `gitshelf_bu_module.sh` to that project's module list; nothing is clobbered |

## Which file runs when

### Binary mode (`source examples/gitshelf/activate`)

```
1. activate                       guard: is a BashTab shell already live?
                                  (if yes → INFO/WARN no-op, never hijack)
2. activate                       export BU_MODULE_LIST="gitshelf:0.1.0:<dir>/gitshelf_bu_preinit.sh;"
                                  export BU_TOP_LEVEL_MODULE=gitshelf
                                  export BU_USER_DEFINED_CLI_COMMAND_NAME=shelf
3. source bu_entrypoint.sh        parse BU_MODULE_LIST → register preinit callback
                                  source core modules → bu becomes available
4. gitshelf_bu_preinit.sh         runs DURING init: exports GITSHELF_DIR,
                                  registers commands/, config key, stage effects,
                                  help topics
5. bu_mark_load_complete          cache the command registry under key "gitshelf"
```

### Library mode (`source examples/devbox/activate`)

```
1. devbox/activate                export BU_TOP_LEVEL_MODULE=devbox
                                  export BU_MODULE_LIST="devbox:0.1.0:<dir>/devbox_bu_preinit.sh;"
2. source gitshelf_bu_module.sh   appends "gitshelf:0.1.0:<dir>/gitshelf_bu_preinit.sh;"
3. source bu_entrypoint.sh        parse BU_MODULE_LIST (devbox + gitshelf)
                                  source core modules → bu becomes available
4. devbox_bu_preinit.sh           registers devbox's commands/ and help topic
5. gitshelf_bu_preinit.sh         registers gitshelf's commands/ and help topic
6. bu_mark_load_complete          cache the WHOLE registry under key "devbox"
```

> The two rules that make this composition safe: a host sources the library's
> `*_bu_module.sh` (never its `activate`, which would fight for the top-level
> role), and only the top-level calls `bu_mark_load_complete` (the library's
> commands are cached under the host's key).

## Configuration

`config/shelf.json` maps a repo name to a path, tags, and comment:

```json
{
    "repos": {
        "bashtab":  { "path": "~/src/BashTab", "tags": ["shell"], "comment": "the framework itself" },
        "dotfiles": { "path": "~/dotfiles",    "tags": ["home"],  "comment": "" }
    }
}
```

- `GITSHELF_CONFIG_FILE` overrides the config path (registered via
  `bu_config_register`, so it shows up in `bu set-config` / `bu get-config`).
- `GITSHELF_RESOLVE_PATH_CALLBACK` lets a host override how a configured path
  is resolved (the default expands a leading `~`).
- `GITSHELF_BASHTAB_DIR` locates the BashTab checkout (defaults to a relative
  path inside this repo, since the demo lives under `examples/`).
- `GITSHELF_CLI_NAME` renames the CLI (default `shelf`).

## Help

```sh
shelf get-help gitshelf        # the module's own subsystem help page
shelf get-repo --help          # autohelp + SEE ALSO back-reference
```
