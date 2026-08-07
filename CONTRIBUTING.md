# Contributing

Thanks for looking. This page is the practical half - what to install, what to
run, and what a reviewable change looks like here. The design half is
[`README.md`](README.md) for what the binary promises, and
[`research/relate/`](research/relate/CLAIM.md) for the product thesis, the
mathematical ancestry, and the record of what we tried to falsify it with.

Two other files bound this one. Report a vulnerability privately, never in an
issue: [`SECURITY.md`](SECURITY.md). How we treat each other:
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## What this repository is, and what it is not

`relate` is compression-as-search: the kinship metrics, the unit anatomy, the
Ziv-Merhav quotation parse, the persisted atlas and shelf, the grade
calibration, and the verbs that turn all of it into a product. It is one of
three faces over the same floor. The **engine** is [`irregex`][irregex] - the
regex engines, the corpus walk, the FM-index, the freshness law. The **chassis**
is [`gist`][gist] - the argv machinery, the resident daemon, and the answer keep
this binary dials into.

That split decides where an issue goes. "`similar` ranked a stranger above a
fork", "`echoes --shape families` split one family in two", "the atlas answered
differently than a cold run", "`pack` picked two copies of the same file" - all
here. "This `--matching` pattern matched the wrong span" is the engine's. File
it wherever you like; we move it rather than bounce you.

**You need three checkouts.** This package cannot build from its own clone: its
`build.zig.zon` path-depends on `../irregex` and `../gist`, and all three
bindings path-depend on the siblings independently. Clone them beside each
other:

```text
Billy-Company/
├── irregex/     ← the engine, required to build this
├── gist/        ← the chassis, required to build this
├── relate/      ← you are here
└── blast/       ← composes this one; not needed to build it
```

This is why CI checks out three repositories into subdirectories of one
workspace: `actions/checkout` refuses a path outside the workspace, and nothing
in the package is patched for CI on purpose. What builds there is the layout you
actually clone.

## Setup

| For | Install | Pinned by |
| --- | --- | --- |
| the binary | Zig **0.16.0** | `minimum_zig_version` in [`build.zig.zon`](build.zig.zon), `ZIG_VERSION` in CI |
| the Python binding | [uv](https://docs.astral.sh/uv/) | `requires-python` floor 3.12 |
| the Rust binding | rustup | `bindings/rust/rust-toolchain.toml` |
| the Go binding | Go | `bindings/go/go.mod` |
| the discipline gate | markdownlint-cli2, typos, shellcheck, golangci-lint | the actions in [`ci.yml`](.github/workflows/ci.yml), mirrored into `.mise.toml` |
| the topology gate | [zoning](https://github.com/The-Billy-Company/zoning) **0.1.1** | the `topology` job in [`ci.yml`](.github/workflows/ci.yml), mirrored into `.mise.toml` |
| coverage | kcov | only for `zig build coverage`, a local instrument |

If you run [mise](https://mise.jdx.dev), that table is one command:

```bash
mise install
```

`.mise.toml` pins every row at the version CI uses and `mise.lock` carries the
checksums for all four release platforms. The pins are mirrors of the files in
the third column and never the authority, so bumping one means bumping the
other in the same commit. kcov is the exception and stays a `brew install`: it
backs a local instrument nothing gates on, and there is no package to pin.

What no lockfile can install is the sibling. relate builds against `irregex`
checked out beside this repo - versions are a package manager's job, a checkout
is not.

```bash
zig build                 # ReleaseFast relate → zig-out/bin/relate
zig build check           # compile only - the fastest "did I break it"
zig build check --watch   # ... and again on every save
zig build test            # the suite
zig build lab             # the measurement harness; not something CI runs
```

## The test loop

The suite is sharded and filterable, and using that is the difference between a
fast loop and a coffee break:

```bash
zig build test -Dtest-filter='<substring>'   # just the tests you touched
zig build test -Dtest-skip='<substring>'     # everything except those
zig build test -Dtest-shards=1               # one process, for a debugger
zig build test -Dtest-optimize=Debug         # steppable binary
```

The test binary is ReleaseSafe by default on purpose: the differential suites
exist partly to trip safety checks, and a ReleaseFast build elides the checks
they are trying to trip.

Beyond the Zig suite, every binding drives the **real** `relate` binary and
skips when it cannot find one - so a binding suite that ran nothing still exits
0. Build first and put it on PATH, which is exactly what CI does and why CI
asserts the artifact exists rather than trusting an exit code:

```bash
zig build && export PATH="$PWD/zig-out/bin:$PATH"

cd bindings/python && uv run pytest -q
cd bindings/rust   && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
cd bindings/go     && go vet ./... && go test ./...
```

## The constraints a change is held to

`relate` is the native lane of the ecosystem - it keeps no grep syntax, because
these are not grep-shaped questions. What it keeps instead is narrower and
easier to break:

- **There are two kinship questions, and the surface says so.** `similar` is one
  probe against the corpus; `echoes` is the corpus against itself. Four earlier
  verbs - `search`, `dups`, `clusters`, `concepts` - turned out to be corners of
  those two, reached by a flag. A new **verb** therefore has to argue that it is
  a genuinely new question rather than an axis on an existing one, and the
  default answer is a flag. Retired spellings exit 2 naming their replacement,
  and that is a feature: do not turn one back into an unknown-command error.
- **A warm answer is byte-identical to a cold one.** The atlas and the fragment
  atlas are an optimization tier, never a dependency - a missing or corrupt one
  degrades to a live build, and `--no-index` forces it. If you touch the
  artifacts, the freshness fold, or the keep, the check that matters is that the
  accelerated answer matches the un-accelerated one on a real tree. That
  comparison is one command; run it.
- **Grades are what keep a ranking honest.** Ranking always returns rows, so
  every row carries a calibrated band and an answer made only of background says
  so on stderr instead of looking like a find. A change that widens a band, or
  drops the floor a record needs before it is allowed to have a number, is a
  change to what "kin" means - argue it in the PR, and expect
  [`contract/kinship.toml`](contract/kinship.toml) to move with it.
- **Noise floors belong to the channel, not the caller.** 16 min-hashes for
  bytes, 8 fingerprints for structure. If you find yourself exposing a knob so a
  caller can lower a floor until an answer appears, the floor was not the
  problem.

## What CI will check

Eight jobs in [`.github/workflows/ci.yml`](.github/workflows/ci.yml), split on
purpose - a Zig engine regression, a Rust clippy nit, and a prose error are
different news and deserve different red Xs.

| Job | What it holds |
| --- | --- |
| `engine` | `zig build check` + `zig build test` on Linux and macOS |
| `python` / `go` / `rust` | each binding's suite against a freshly built binary; Ruff, golangci-lint, Clippy, and `cargo deny` hold their language surfaces |
| `fmt` | `zig fmt --check` over every tracked and untracked-not-ignored `.zig` file |
| `version` / `contract` | package versions agree, and irregex's vendored kinship contract still matches this one |
| `discipline` | Markdown, spelling, YAML, TOML, EditorConfig, shell, Python format, and GitHub Actions security |

The separate [`windows`](.github/workflows/windows.yml) workflow runs the Zig
suite, CLI smoke, and idempotent installer on native x64 and arm64 Windows.
Cross-compilation is not treated as runtime evidence.

Absent on purpose: `lab`, `relate-knn`, and `codex-scale`. They are measurement
instruments, and a timing number produced on a shared runner is noise wearing a
decimal point.

Run the formatter before you push - `zig fmt` reflows column-aligned literals,
so a rename that shrinks the widest cell leaves rows you never touched one space
too wide:

```bash
zig fmt .
```

## Benchmarks are evidence, and the bar is absolute

There is no case where an incumbent is allowed to win. Where a claim is about
recall or precision rather than speed, it needs a corpus and a number, not an
anecdote about one file.

- Numbers come from a harness in [`bench/`](bench/), on a quiet machine, against
  the rung being claimed - not from a stopwatch and a hunch.
- Profile the function you changed rather than re-running the whole slate and
  squinting at the total.
- If output is supposed to be byte-identical, prove that it is.
- A claim about the *quality* of an answer belongs in
  [`research/relate/TESTING.md`](research/relate/TESTING.md) with the thing it
  was measured against. That file is where we keep what failed, too.

## Every change carries its own news

Write a towncrier fragment in the **same PR**:

```bash
towncrier create '+<slug>.<type>.md'    # types: added changed deprecated removed fixed security
```

Fragment names read like the sentence they are:
`+the-fm-index-shelf-moves-to-irregex.changed.md`. The leading `+` tells
towncrier there is no issue number attached. The body is prose for a person
reading release notes - what changed and what it means for them, not a
restatement of the diff.

Skip it only for comment-only, format-only, or genuinely invisible internal
work. When unsure, write it.

## The version is written once

You will not edit a version by hand, and you should not try. `build.zig.zon`'s
`.version` is the only place this package's number is written:

- **Zig** reads it through a build option, which is what `relate --version` and
  the `--schema` manifest answer with;
- **Rust** reads `CARGO_PKG_VERSION`;
- **Python** reads its installed distribution metadata.

That leaves `Cargo.toml` and `pyproject.toml`, which cannot import anything.
Both carry an `x-release-please-version` marker, `release-please-config.json`
lists them, and one merged release PR moves all three in a single commit.
`python3 tools/version_parity.py` proves they agree, and fails just as loudly on
a marked line the release config was never told about. It runs in CI.

The engines underneath are different axes. `irregex` and `gist` version on their
own schedules and are pinned as dependencies, never mirrored here. This face
used to print the engine's version as its own - 1.0.0 against a package at
0.1.0 - which is exactly what the arrangement above makes impossible.

**Cutting a release.** Merge the release PR that release-please opens; that tags
`vX.Y.Z` and `release.yml` publishes the wheels. towncrier owns `CHANGELOG.md`,
so run `towncrier build --version <the version the PR bumps to>` and push it
onto the release branch - the tag and the notes should land together.

This repository's tag, changelog, and publish steps are one instance of a
model shared across every Billy-Company OSS package - see
[RELEASING.md](https://github.com/The-Billy-Company/.github/blob/main/RELEASING.md)
for the lifecycle this feeds into and why it's shaped this way.

## Commits and pull requests

Commit subjects here are a conventional prefix plus a lowercase sentence that
says what changed, in the voice of the change rather than the ticket:

```text
fix: a temp corpus needs temp artifacts
feat: the kinship contract comes home
ci: the workflow can read its own siblings
```

Prefixes in use: `feat` `fix` `perf` `refactor` `docs` `test` `build` `ci`
`chore`. Keep the subject under about 72 characters and put the reasoning in the
body, where reviewers and `git log` both find it.

The subject line becomes the squash commit message, and that is what
release-please reads to pick the next version: a `!` or a `BREAKING CHANGE:`
footer takes the major, `feat` takes the minor, everything else takes the
patch. An unconventional title is not a style nit. Nothing in this repo's
config overrides that, so a release is a minor only because someone shipped a
feature in it; if you need an exact number the rules would not pick, the
`Release-As: X.Y.Z` footer is documented with the full table in the org
standard, [What Picks the
Number](https://github.com/The-Billy-Company/.github/blob/main/RELEASING.md#what-picks-the-number).

For the pull request: one concern per PR, describe what would have caught the
bug if it had existed, and fill in the template. Reviews here ask three
questions more than any others - *what proves this?*, *what does it cost?*, and
*what did it replace?* Answering them in the description saves a round trip.

If you removed something that a newer path superseded, remove it completely.
Leaving the old implementation beside the new one to be safe is how a codebase
grows two spellings of the same bug.

## Architecture is machine-checked

Zig has no visibility rules between files in a package, so every boundary the
READMEs describe would be convention.
[`charter.zone`](charter.zone) is the machine-checkable half: a
zone list, low to high, where an import may only point back up the page. If your
change needs a new import edge, edit the contract in the same commit and say why
in the variance. Do not route around it.

`mise install` puts `zoning` on your PATH, so you can run it while you edit
instead of reading its verdict in review: `zoning verify` is what the topology
job runs, `zoning map` draws the zone stack, and `zoning status --suggest`
drafts the variance a new edge would need.

The vocabulary has the same property.
[`contract/kinship.toml`](contract/kinship.toml) is where the record kinds, the
channels, the grade bands, the closed verb set, and the retired spellings are
declared - and the `gist` repository vendors a copy to check its bindings
against. Change the meaning of a channel there, not in five places.

## Licensing

This project is Apache-2.0. There is no CLA: contributions are accepted under
the same license the project already carries, per the inbound=outbound norm in
section 5 of the license itself.

If you bring in third-party code, data, or an idea from a paper, it goes in
[`NOTICE`](NOTICE), the citation goes in
[`research/relate/PRIOR_ART.md`](research/relate/PRIOR_ART.md), and the credit
goes at the call site. Nearly every metric here is somebody's published result;
saying whose is part of the work rather than a courtesy.

## A small thing that makes diffs readable

Git ships hunk-header patterns for Go, Python, Rust, C, and Markdown, and
[`.gitattributes`](.gitattributes) already binds them. Zig has none, so teach
your own git what a Zig declaration looks like once:

```bash
git config diff.zig.xfuncname '^((pub |export |inline |noinline )*fn .*|(pub )?(const|var) [A-Za-z_].* = (struct|union|enum|opaque)\b.*)$'
```

The attribute is already in place; until you run this, it simply falls back to
git's default.

[irregex]: https://github.com/The-Billy-Company/irregex
[gist]: https://github.com/The-Billy-Company/gist
