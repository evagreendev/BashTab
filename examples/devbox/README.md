# devbox — a tiny host project

`devbox` is the companion to the `gitshelf` demo. It consumes gitshelf as a
**library** dependency, proving the library/binary duality that is the core of
the BashTab module system.

```sh
source examples/devbox/activate
```

One shell, one command registry, one cache key, one help system:

```sh
devbox get-env                  # devbox's own command
devbox get-repo                 # gitshelf's command, via devbox's CLI name
bu get-module --format table    # lists BOTH modules (devbox and gitshelf)
```

## How it works

`activate` is the top-level entrypoint. It:

1. sets `BU_TOP_LEVEL_MODULE=devbox` (the cache key),
2. seeds `BU_MODULE_LIST` with devbox's own entry,
3. sources `gitshelf_bu_module.sh` — the library entrypoint — which appends
   gitshelf's entry to the same list,
4. sources `bu_entrypoint.sh`, which runs both preinit callbacks, and
5. calls `bu_mark_load_complete` once, caching the whole registry under
   `devbox`.

> Two rules make this safe: a host sources the library's `*_bu_module.sh`
> (never its `activate`, which would fight for the top-level role), and only
> the top-level calls `bu_mark_load_complete`.

See `examples/gitshelf/README.md` for the full binary-vs-library story.
