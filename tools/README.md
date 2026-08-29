# `tools/` — maintenance gates

Standard library only, no build step — run them with `python3 tools/<name>.py`.

| Tool                | Asks                                                            |
| ------------------- | --------------------------------------------------------------- |
| `version_parity.py` | do every mirror of `build.zig.zon`'s `.version` still agree, and does the release bot know about each one? |
| `registry_readme.py` | does every relative link in `README.md` still resolve, so no published page carries a dead one? |
| `relock.py` | does `Cargo.lock` still pin our own packages at the versions the manifests beside them declare — and if not, fix it? |

```bash
python3 tools/version_parity.py          # the gate (CI's `version` job)
python3 tools/version_parity.py --json   # the mirrors it found, for a machine
```

## The lock nobody rewrites

`version_parity.py` above covers the manifests, because a manifest carries a
marker the release bot can find. A lockfile carries none: it is resolver output,
and the resolver is normally the only thing that writes it. So the version it
records for `relate-search` falls behind the moment release-please bumps
`Cargo.toml`, and the one it records for `irgx` goes stale on irregex's schedule
rather than on ours — this repository can wake up with a stale lock because a
sibling released overnight.

Nothing in CI notices, because nothing in CI passes `--locked`. `cargo publish`
does, deliberately: the point is to ship the graph that was tested rather than
whatever the index offers at upload time. So it surfaces at the one moment it is
most expensive — relate's v1.1.0 and two of gist's releases each died there with
the wheel and the Go module already out.

`relock.py` is the repair, and it rewrites rather than resolves: it walks the
manifest graph to learn which packages are local, reads each declared version
off disk, and writes it into the matching `[[package]]` block. No registry is
contacted, so no third-party pin can move. The release workflow runs it just
before `cargo publish --locked`.

```bash
python3 tools/relock.py bindings/rust           # re-pin in place
python3 tools/relock.py bindings/rust --check   # exit 1 if a pin is behind
```

## The README, on an index that is not GitHub

PyPI and crates.io each show a README as the whole project page, and each
resolves a relative link against its own URL rather than against GitHub. A
repository-relative path is a 404 under `pypi.org/project/relate-search/`, and on
crates.io a well-formed URL into the crate's own subdirectory pointing at a file
that was never there - the worse of the two, because nothing looks broken.

`registry_readme.py` is the one rewriter both ends share. It absolutizes every
relative target against the `repository` URL the manifest already declares -
`raw` for an image, `tree` or `blob` by what the path is on disk - and refuses
outright on a target the repository does not contain. Python calls it from
`bindings/python/hatch_readme.py` at wheel-build time, so the corrected page
exists only inside the artifact. Cargo has no metadata hook, so for crates.io
this writes `bindings/rust/PROJECT_README.md`, which is gitignored and which
`readme` points at: `cargo package` fails loudly if it was never generated, and
`cargo build` never reads it.

```bash
python3 tools/registry_readme.py --check   # the gate (CI's `version` job)
python3 tools/registry_readme.py           # mint bindings/rust/PROJECT_README.md
```

Mint it immediately before `cargo package`, never earlier. A missing file fails
loudly; a stale one would ship quietly, so absent is the state to leave it in.

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
