# `tools/` — maintenance gates

Standard library only, no build step — run them with `python3 tools/<name>.py`.

| Tool                | Asks                                                            |
| ------------------- | --------------------------------------------------------------- |
| `version_parity.py` | do every mirror of `build.zig.zon`'s `.version` still agree, and does the release bot know about each one? |

```bash
python3 tools/version_parity.py          # the gate (CI's `version` job)
python3 tools/version_parity.py --json   # the mirrors it found, for a machine
```

## One version, and where the copies are

`build.zig.zon`'s `.version` is the single place this package's version is
written. `src/root.zig` reads it through a build option — which is what
`relate --version` and the `--schema` manifest answer with — Rust reads
`CARGO_PKG_VERSION`, and Python reads its installed distribution metadata. None
of them restate the number.

What remains is the two publishing manifests, which cannot import anything.
Each carries an `x-release-please-version` marker that `release-please-config.json`
lists and the release bot rewrites in one commit. This gate discovers those
markers rather than holding a list, so it fails both on a mirror that drifted
and on one the release config never learned about.

The engine underneath is a **different axis**: `irregex` and `gist` version on
their own schedules and are pinned as dependencies, never mirrored here. Both
faces used to print the engine's version as their own — 1.0.0 against a package
at 0.1.0 — which is the drift this arrangement exists to make impossible.
