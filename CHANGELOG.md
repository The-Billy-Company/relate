# Changelog

All notable changes to `relate` (the similarity engine) are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions track
`build.zig.zon`.

<!-- towncrier release notes start -->

## [1.1.1] - 2026-08-14

### Fixed

- A version bump moved `Cargo.toml` and left the lockfile behind, and `--locked`
  is the flag whose whole job is to refuse to fix that. A lockfile records the
  version of every package it locks, including the one it sits next to, so the
  release bumping the manifest through its `x-release-please-version` annotation
  put the two a version apart. `cargo publish --locked` then stopped with "cannot
  update the lock file because --locked was passed", which is correct behaviour and
  a wedge: nothing about it improves on a retry, so the crate never reaches the
  registry no matter how many times the release runs.

  `gist` hit it on v1.2.0 with the wheel and the Go module already published, so
  the tag existed and the crate did not. The committed lock was stale in the tree
  too, which means `cargo build --locked` in `bindings/rust` was already failing
  for anyone who tried it.

  The publish now re-pins the lock's own version from the manifest beside it
  first, hermetically - a `version = "..."` rewrite and nothing else, so no
  third-party pin can move and the graph being published is still the one that was
  tested, which is the reason `--locked` is there at all. `cargo update
  --workspace` was the first attempt and the wrong one: it resolves the whole
  graph, so it wants a sibling `irregex` checkout for the `irgx` path dependency
  that this job has no reason to make, and relate's v1.1.0 failed exactly there
  while `cargo publish --locked` had never needed it.

  `cargo publish` also resolves the manifest it is publishing, path dependencies
  included, before it rewrites them into registry ones. `relate` and `blast` were
  checking out only themselves, so the `../../../irregex` beside them pointed at
  nothing and the publish died on a missing `Cargo.toml` - which is how blast's
  v1.1.0 was lost with its wheel and Go module already shipped. Both now place
  their own checkout and irregex's side by side, the way `gist` already did, so
  that relative path means what it says.

## [1.1.0] - 2026-08-14

### Added

- A `note` fragment type, for the paragraph that frames a release rather than an
  entry in it. Towncrier renders types in declaration order and `note` is
  declared first, so it lands above `### Added` with no template fork and
  retires itself on fold like any other fragment.
- The Python binding has an import contract: `bindings/python/binding.zone`,
  governing `relate-search` the way `charter.zone` governs the Zig side.

  The package is flat on purpose - `corpus` holds the scope, the timeout, and the
  run helper that `kinship`, `retrieval`, `sweep`, and `lifecycle` are each a
  specialization of - so the contract says one zone and means it, rather than
  inventing tiers between peers. What it does pin is the reach outside: `irgx`
  underneath, `gist` in the tests only, as the independent oracle a
  compression-based verdict should be checked against.

  Needs `zoning` 1.3.1, which is where the `python` dialect and root-anchored
  contracts both arrive.

### Changed

- Public examples still borrowed wallet, billing, and service names from the
  private corpus. They now use Acme vocabulary instead.

  The measured benchmark probes are unchanged. This only moves illustrative docs,
  docstrings, and correctness fixtures.
- The import contract moved to `charter.zone` at the repository root, out of the
  `contract/` drawer and out from under the package's own name.

  Two things were wrong with the old spelling. A contract governs the directory it
  sits in, so a folder holding one page bought nothing - the manifest, the
  formatter config, and the CI config all already live at the root, and this
  belongs beside them. And naming it after the package spent the filename on a
  third copy of a name that is already on the file's first line and already in the
  path, which meant every repository in the ecosystem called the same kind of
  document something different.

  `charter.zone` is that one name. Nested packages take a role name instead -
  `kernel.zone`, `service.zone` - because there the path already says which one it
  is. Identity was never in the filename: the `package` block is what every
  verdict, every `--package` filter, and every workspace lookup reads, so nothing
  downstream can tell the two spellings apart. Needs `zoning` 1.3.1, which is
  where a contract at a package root is first discovered; the pin moves with this.

### Fixed

- A version bump moved `Cargo.toml` and left the lockfile behind, and `--locked`
  is the flag whose whole job is to refuse to fix that. A lockfile records the
  version of every package it locks, including the one it sits next to, so the
  release bumping the manifest through its `x-release-please-version` annotation
  put the two a version apart. `cargo publish --locked` then stopped with "cannot
  update the lock file because --locked was passed", which is the correct
  behaviour and a wedge: nothing about it improves on a retry, so the crate never
  reaches the registry no matter how many times the release runs.

  `gist` hit it on v1.2.0, with the smoke tests green on all six targets and the
  GitHub release already published, so the tag exists and the crate does not. The
  committed lock was stale in the tree too, which means `cargo build --locked` in
  `bindings/rust` was already failing for anyone who tried it.

  The publish now re-pins first, with `cargo update --workspace`. That moves only
  the local packages, against the manifests beside them, and leaves every
  third-party pin exactly as committed - so the dependency graph being published
  is still the one that was tested, which is the reason `--locked` is there.
- Both published packages declared Apache-2.0 and carried none of it. The license
  text and the NOTICE live at the repository root, and neither a `.crate` tarball nor
  a wheel can reach above its own project directory - so the crate shipped an SPDX
  string and no license, and the wheel shipped the same. Section 4 of that license
  asks a redistributor for exactly those two files, which made this the one packaging
  defect that was not cosmetic.

  `LICENSE` and `NOTICE` are now committed beside both manifests, byte-identical to
  the root pair. The wheel names them in `license-files`, so they land in
  `.dist-info/licenses/` rather than only inside the sdist, where nobody installing
  the wheel would ever see them.

  `rust-toolchain.toml` stops shipping in the crate on the same pass. It pins 1.96.0
  so this repository's contributors lint identically - no business of anyone building
  the extracted crate, and it would have quietly overridden the 1.85 `rust-version`
  the sources actually ask for.
- CI cancelled its own evidence on `main`. The concurrency group keyed on the ref
  and cancelled unconditionally, which is right on a branch whose runs are drafts -
  a force-push should kill the run it obsoleted rather than race it - and wrong on
  `main`, where every commit is a candidate to be released and the run is the only
  record of whether it may be.

  `release.yml` will not publish a tag unless `release-ready` concluded success on
  that exact commit, which is the check that makes a green release meaningful. But
  `release-ready` gathers its dependencies under `if: always()`, so it reports on
  jobs that never finished as readily as on jobs that failed. So the next push to
  main revoked the previous commit's verdict: a still-running job ended
  `cancelled`, `release-ready` read that as a failure, and preflight declined a
  release with nothing wrong with it. On a tree several people push to, that is
  not a rare race; it is most releases, and it looks exactly like a real test
  failure until you notice the conclusion is `cancelled` rather than `failure`.

  Caught it on `gist`, whose v1.2.0 tag was green on the pull request and then lost
  the release commit's `python (3.14)` job to three docs commits landing behind the
  merge. Every repository in the family had the same line, so every one has the
  same fix: pushes to main no longer cancel each other and each commit keeps its
  own answer, while pull request branches still supersede as before.
- The GitHub Release page now carries the changelog section it names. Two
  changelogs were produced per release and only one of them was towncrier's:
  `skip-changelog` hands `CHANGELOG.md` to the fragments, but that key governs
  the *file*, and composing the release **body** is a separate path inside
  release-please that kept running off conventional-commit subjects. So the page
  people land on was assembled from commit subjects while the notes someone
  wrote sat in the changelog - irregex v2.1.1 published two lines against a
  folded section of a hundred and ten, because eleven of its thirteen commits
  were `ci:` or `docs:` and both are hidden. A `notes` job now posts the folded
  `## [X.Y.Z]` section over that body on tag, waiting for the release to exist
  rather than assuming it already does, and truncating at a whole bullet under
  GitHub's 125,000-character body ceiling rather than failing on a tag that is
  already immutable.
- The Install section only knew how to build the CLI from source, which was the
  whole story right up until the three bindings shipped. It now names each one
  where it is actually served: `relate-search` on PyPI and crates.io, the module
  path on the Go proxy, and the identifier you type in each - still `relate`,
  because the `-search` suffix is a registry fact rather than an API one.

  The Rust README carried the stalest line, promising a "crates.io version once
  published" for a substrate that has been [`irgx`](https://crates.io/crates/irgx)
  1.0.0 for a while now, and had no install snippet of its own at all.

  All three also say what none of them said before: the binding drives the
  `relate` binary rather than reimplementing it, so the CLI is a prerequisite, and
  a missing one raises `GistNotFoundError` rather than returning nothing.
- Three bugs in the release machinery, each of which alone was enough to stop a
  release, and together they are why main has said 1.1.0 since August with `v1.0.0`
  still the newest tag.

  `release-please-config.json` named the package. With `include-component-in-tag`
  off, release-please writes a standalone release PR's body with no component in it,
  and names the branch `release-please--branches--main` with no component either.
  Then, on merge, before it will tag anything, it compares that empty component
  against `component || package-name` - so a `package-name` here makes the two
  halves of its own bookkeeping disagree permanently. Every merge logged
  `PR component: undefined does not match configured component: relate-search` and
  returned without creating the tag or the release. That is worse than a missed
  release, because it wedges: an untagged merged release PR makes the *next* run
  abort before it opens anything, so the queue stops until someone relabels the old
  PR by hand.

  The fold's guard read the wrong side of the index. towncrier stages its own
  edits; it writes the newsfile and retires each fragment through `git add` and
  `git rm`, so a working-tree-vs-index diff is quiet the instant it finishes, even
  though it just rewrote CHANGELOG.md. The job compared against the index rather
  than HEAD, printed `nothing new to fold`, and exited 0 having done nothing. Every
  fragment this release was supposed to publish is still sitting in `changelog.d/`.

  And the fold only ran on the push where release-please rewrote the PR. The
  action sets its `pr` output only when it wrote something, so a `ci`/`docs` commit
  carrying a new fragment, which changes no version and therefore no note, left
  that output empty, and the job skipped with nothing saying so. The branch is now
  resolved from the `autorelease: pending` label instead, which is release-please's
  own marker for the PR it is holding open rather than a name guessed from a
  convention.

  `.release-please-manifest.json` claimed 1.1.0, a release that never happened -
  no tag, nothing on crates.io or PyPI, no changelog section. Left alone it would
  have made the next release bump *past* a number nobody can install, so it is back
  to 1.0.0, the newest version that actually shipped. The next release therefore
  re-cuts 1.1.0 with all of the fragments this one was supposed to publish, and the
  version already written into `build.zig.zon` on main becomes true rather than
  aspirational.

  With `always-update` on, the branch is rebuilt on every push while the PR is
  open, so the fold recomputes from main rather than appending to whatever the
  branch already carries - towncrier treats a second write of the same version as a
  hard error, not a no-op.
- `--matching` handles `BoundUnsupported`, the fault `irregex` grew when its C ABI
  learned bounded-window search. The switch over compile faults is deliberately
  exhaustive - a new fault in the engine is meant to be a compile error here rather
  than a mystery string in someone's terminal - so this is that mechanism working:
  the engine added a member and this is the line that answers for it.

  Nothing can produce it through `--matching`, which offers neither `-P` nor a
  window bound. It is reported by name rather than asserted away, because a fault
  that cannot happen is still cheaper to print than to trip over.
- `relate` did not build at all, and the error blamed a file nobody had touched: `gist/src/root.zig:1:1: file exists in modules 'irregex' and 'irregex0'`.

  Zig keys dependency dedup on the whole option set, not on target and optimize. `gist` asks the engine for `lib-optimize` so its C-ABI pair matches its own mode; relate asked for two options where gist asks for three, so the two calls resolved to two separate instances of the same `irregex/src/root.zig`. Nothing collides while they stay apart - which is why the library built fine - and the moment one binary imports both relate and gist, they land in one compilation and the compiler refuses one file as the root of two modules. The build graph reads as if it matched; only the link says otherwise.

  So the option set now lives in one function, `engineOptions`, instead of at three call sites that had to agree by eye. That is the actual fix: matching target and optimize was necessary and never sufficient, and a comment saying "same target/optimize on every sibling" is not something a fourth call site can be held to.

## [1.0.0] - 2026-08-02

### Added

- A face with one verb everybody types still made you type it. `blast blast
  Corpus` is the shape the manifest forced, and the stutter is not a naming
  accident - it is the dispatcher having no way to hear a bare argument as a
  verb's argument.

  A `Face` can now declare `bare`, the verb that runs when `argv[1]` is not
  one. `bareFor` resolves it only when the token collides with no verb, no
  retired name, and no flag, so `blast index` still means the verb and `blast
  -h` still means help; a symbol that happens to share a verb's name stays
  reachable by spelling the verb out.

  `--schema` reports the default so an agent can see it without guessing, and
  the help renderer shows the verbless form as the invocation.
- A fifth CI job, and it checks the one formatter nothing here was checking.
  Rust already had `cargo fmt --check` inside its own job; Zig, which is what
  this
  package is actually written in, had nothing.

  That gap is not theoretical. `zig fmt` lays a column-aligned multiline
  literal
  out as a padded grid, so a rename that shrinks the widest cell in a column
  leaves every row beneath it one space too wide — in files nobody opened. The
  sibling substrate shipped exactly that and no gate said a word. This one
  found
  committed drift here on its first run.

  Its own job, for the reason the other four are: a formatting nit and an
  engine
  regression should not arrive as the same red X. It is also the only job here
  that skips the three-checkout preamble, because reading files is not
  configuring a build and none of the sibling path dependencies apply. It pins
  the same Zig the engine builds with, since the formatter's output is a
  property
  of the compiler release — a different Zig is a different grid.

  The file list is enumerated with `git ls-files -co --exclude-standard
  '*.zig'`
  rather than written out, because a path list goes stale the same silent way
  the
  formatting does, and stale in the direction that checks less. Tracked plus
  untracked-not-ignored is 53 files today, and a new top-level directory cannot
  escape it. What it leaves out is exactly the ignored trees, `.zig-cache` and
  the fetched `zig-pkg/`, so the exclusions live in `.gitignore` where someone
  can read them, instead of being whatever fell outside an argument list. The
  one
  piece that looks like belt-and-braces is the existence test on each path, and
  it is not: `git ls-files` still names a tracked file you have deleted, so
  without it a mid-edit working tree fails the gate with `FileNotFound` and
  teaches everyone to ignore it.
- Apache-2.0, matching the rest of the ecosystem: the same permissive freedoms
  as MIT plus an explicit patent grant, a NOTICE obligation, and a
  stated-changes requirement. NOTICE attributes the one thing bundled here —
  libsais 2.10.2 under `vendor/libsais/`, itself Apache-2.0 — and separates it
  from the algorithms implemented from published descriptions (LZJD,
  Ziv–Merhav, SA-IS, RRR, wavelet trees, FM-index), which stay credited at
  their point of use and in `research/relate/PRIOR_ART.md`.
- Every one of these repositories has shipped a `deny.toml` since the crate
  existed, and not one of them ever ran it. Four checks were written down and
  none enforced: a RustSec advisory against anything in the graph, the banned
  crates that would mean a regex binding grew a TLS stack or an async runtime,
  the license allowlist, and which registries a crate may come from. A policy
  nobody runs is a policy nobody has.

  So `cargo deny check` is a step in the `rust` job now, on a prebuilt binary
  rather than the Docker action - that action takes a repo-root-relative
  manifest path and the checkout layout differs in every repo here, so a plain
  step inheriting the working directory is both shorter and harder to get
  wrong.

  It passed first try in all four, which is the good version of this news and
  also exactly why it needed wiring: nothing was wrong, so nothing would have
  said when something became wrong. One thing needed saying out loud. The
  allowlist is a policy - the licenses this project accepts - not a snapshot of
  today's graph, so most entries go unmatched and cargo-deny warns once each.
  Shrinking the list to silence that would invert the point, because the next
  permissively-licensed crate would fail and get fixed by widening the list
  again, one entry at a time, with nobody deciding anything.
  `unused-allowed-license = "allow"` says that instead.
- The LZJD kinship sketch (`relate similar`/`dups`/`clusters`) grew an external
  differential-oracle suite (`sketch_oracle_test.zig`) that proves the number
  is the RIGHT number, not just a well-behaved one. Where the existing tests
  assert the distance's properties (identity, symmetry, range,
  cluster-by-kind), the oracles check it against three references the sketch
  never computes for itself. First, `build()` is proven byte-exact against the
  true bottom-k of the LZ78 phrase-hash set computed OFFLINE with a std hash
  map and a sort — a streaming-top-k vs sort-then-truncate differential that
  catches any heap, open-addressing, phrase-reset, `min_phrase`, or `finalize`
  bug in construction with zero tolerance. Second, on inputs whose sketches
  saturate the k=128 budget the KMV `distance` estimate is held within the
  estimator's standard error (≈1/√k) of the EXACT set Jaccard it only samples
  (measured independently, no bottom-k). Third, the sketch is made to rank a
  near-edit / heavy-edit / disjoint-alphabet ladder identically to a real
  compressor's normalized compression distance (actual deflate bytes via
  `std.compress.flate`) — the source papers' "same signal as NCD" claim,
  encoded honestly as the rank agreement it is: the suite records that LZJD's
  phrase boundaries cascade-desync under scattered edits where deflate's
  sliding window realigns, so the two agree on order but not magnitude. Only
  the phrase-identity contract (FNV-1a + splitmix64 + `min_phrase`) is shared
  with the implementation; the sampling machinery under test is re-derived by
  independent means.
- The paper trail is code now. CI checks Markdown, spelling, YAML, TOML,
  EditorConfig, shell, Python, Go, Rust, and the GitHub Actions perimeter;
  editor tasks and formatters run the same loop before a push.
- The repository had a license, a NOTICE, and five CI jobs, and nothing that
  told
  a contributor how to work in it. It now carries the paper trail a public
  project is supposed to have.

  [`CONTRIBUTING.md`](CONTRIBUTING.md) is the practical half: that this package
  cannot build from its own clone and needs `irregex` and `gist` beside it,
  what
  each toolchain is pinned by, how to use the sharded suite instead of paying
  for
  the whole thing, and why every binding suite skips itself into a green run
  unless you build the binary first. It also states the constraints a change is
  actually held to - there are two kinship questions and a new verb has to
  argue
  it is not an axis; a warm answer is byte-identical to a cold one or the atlas
  is
  broken; a grade band is a claim about what "kin" means and moves
  `contract/kinship.toml` with it.

  [`SECURITY.md`](SECURITY.md) names the threat model this face has that its
  siblings do not. The corpus is the attacker, as everywhere - but `quote` and
  `pack` make **attributions**, and someone acts on those. A phrase attributed
  to
  a file that never held it, an artifact that moves a distance, or a kept
  answer
  that outlives its epoch is a security report here rather than a bug. It says
  what is not one, too: pairwise sweeps cost what pairs cost.

  [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) is Contributor Covenant 3.0, with
  reports going to a maintainer address rather than a committee that does not
  exist. Its "failing to credit sources" clause is not boilerplate here: the
  prior-art dossier's verdict on this whole engine is COMPOSITION, and that
  word
  is only honest if every ingredient is cited at the point of use.

  The dotfiles are small and load-bearing. `.editorconfig` restates what each
  formatter already emits, so an editor save and `zig fmt --check` cannot
  disagree. `.gitattributes` normalizes line endings - kinship is measured over
  bytes, so a CRLF checkout would move every distance in the atlas - marks
  resolver output as generated, binds the hunk-header drivers, and deliberately
  declines `export-ignore`, which would invalidate every url+hash pin that
  already
  exists. `.mailmap` collapses four author spellings into two people.

  On GitHub: `CODEOWNERS` routes review, Dependabot watches the one ecosystem
  it
  can actually resolve here, a pull-request template asks the three questions
  review always asks anyway, and the issue forms ask for the corpus. The
  kinship
  form's most useful field is whether `--no-index` changes the answer, because
  it
  splits "the metric is wrong" from "the atlas is lying" before anyone reads
  code.
- Windows is now a first-class runtime target. `install.ps1` builds and places
  `relate.exe` on the per-user PATH without elevation, optionally builds the
  atlas, and can be rerun safely. Native x64 and arm64 CI execute the Zig
  suite, a real corpus query, and the installer instead of treating a
  cross-compile as runtime evidence.
- `.mise.toml` and a committed `mise.lock` turn the Setup table in
  `CONTRIBUTING.md` into `mise install`. Zig, Rust, Go, Python, and uv are
  pinned at the versions CI already uses, with checksums recorded for all four
  release platforms. The pins are mirrors of `build.zig.zon`,
  `bindings/rust/rust-toolchain.toml`, `bindings/go/go.mod`, and the `--python`
  CI hands uv - never the authority, so a bump has to touch both files or
  nothing resolves the way it reads.

  The discipline gate's binaries are pinned the same way, and for the same
  reason a red X should mean the same thing in both places: markdownlint-cli2,
  typos, shellcheck, and golangci-lint, each at the version its CI step already
  resolves. Two of those come from the versions their actions bundle, which is
  why the markdownlint action moved up to v24.1.0 in the same pass (from v20,
  four majors back) - it had been running markdownlint-cli2 0.18.1, five minors
  behind the 0.23.1 pinned here.

  The other half of the gate is deliberately not here. Ruff, yamllint, taplo,
  editorconfig-checker, and zizmor arrive through `uv run --no-project --with
  <pkg>==<version>`, which is a version authority already - written in the
  workflow, repeated verbatim in `CONTRIBUTING.md`, and needing no install step
  at all. A second pin for those could only ever disagree with the first.

  Two things are deliberately left out. kcov backs `zig build coverage`, a
  local instrument nothing gates on, and it has no package to pin, so it stays
  a `brew install`. And the sibling checkout is not a version at all: relate
  builds against `irregex` sitting beside this repo, which is a thing you clone
  rather than a thing a lockfile resolves.
- `contract/kinship.toml` is new here, and it is the compression plane's own
  contract: how a unit is sketched, what "near" means on each channel, the
  calibrated grade bands and which direction each improves in, the closed verb
  set, the retired spellings that must fail loudly, and how the atlas and shelf
  age.

  None of it is new text. It lived in the kernel's unified contract nested
  under a
  table named `[irregex]` - named for the package that happened to hold the
  file
  rather than the engine it describes. The nesting is gone; `[irregex.grades]`
  is
  simply `[grades]` now.

  `gist` vendors a copy to check its Go, Python, and Rust mirrors against, kept
  current by `gist/tools/sync_contract.py`.
- `librelate` + `include/relate.h` ship `relate_run` for the kinship,
  retrieval,
  and multi-pattern-sweep verbs that used to hide behind `gist_run`. The
  in-process `patterns` / `pattern_counts` sweep moved with them. A host that
  only wants compression-search links this library (plus `libgist` for the warm
  engine and `libirgx` for the row cursor) and never sees search-product
  symbols.
- `relate-knn` and `codex-scale` are wired into `build.zig`. Both sources came
  across in the split with no build graph to reach them, so the k-NN retrieval
  proof and the codex self-index scaling proof were unbuildable code.

  Both had also gone stale against the new package boundary, in opposite
  directions. `knn.zig` still reached for `irregex.relate.zipper` and
  `irregex.api.relate.sketch` — one engine used to hold everything, and the
  `api`
  facade re-exported the second — where the kinship kernels are this package's
  `relate.kinship` today and the facade no longer exists. `scale.zig` reached
  `cento.zig` by a relative path that climbed out of its own module root, which
  Zig rejects; the FM-index it times moved to the engine package while the
  Ziv-Merhav cross-parse that prices a quotation against it stayed here, so the
  lane straddles both roots and now names `cento` through `relate.codex`.

  `zig build lab` installs both; each is also its own named step. Both compile
  at
  the CLI's ReleaseFast posture, since both are timing tools.
- `relate` has CI. Four jobs on push and pull request: the Zig engine (`check`
  then `test`, on Linux and macOS, because the build branches on the host for
  the
  `libtool` re-archive and for `@loader_path` against `$ORIGIN`), plus one job
  each for the Python, Go, and Rust bindings.

  The interesting part is that a clone of this repository cannot build. Every
  face resolves its dependencies as sibling paths; `../irregex` and `../gist`
  in
  build.zig.zon, `../../../irregex/bindings/go` in the Go module's replace, the
  same shape again in Cargo.toml and pyproject.toml. All of those are relative
  to
  the directory holding this one, which a bare checkout does not have. Rather
  than teach CI a second spelling of the dependency graph, the workflow checks
  this repo out one level down and drops `irregex` and `gist` beside it, so a
  runner's layout is a developer's layout and every relative path means the
  same
  thing in both places. `actions/checkout` refuses to write above the
  workspace,
  which is what forced descending rather than ascending.

  The binding jobs each build the Zig CLI, which the substrate's own CI has no
  reason to do. relate vendors no archive of its own, so its bindings answer by
  shelling the `relate` binary and skip when there isn't one. Rust is why that
  became worth guarding: its skip is an early `return`, which the harness
  reports
  as `ok`, so a job that built nothing would have gone green having asserted
  nothing at all. Each build step now proves the binary exists before the suite
  that needs it runs.

  The measurement lanes stay out. `lab`, `relate-knn`, and `codex-scale` are
  timing tools, and a duration measured on a shared runner is noise wearing a
  decimal point.
- `relate` is its own package: the similarity engine (kinship · anatomy · codex
  ·
  compose · retrieval · warm tier + the atlas/frag/shelf artifacts) extracted
  from a package path inside a private monorepo at
  ce430bbaab, depending on the
  `irregex` library as a sibling checkout. The `relate` binary ships from
  `gist`.

### Changed

- "Compression-as-search" is the answer, not the question. Nobody arrives at a
  package index having already decided that compression is how they want to
  find
  duplicated code - they arrive typing "duplicate code", "clone detection",
  "code
  similarity", "near-duplicate files". The metadata was written entirely in the
  first vocabulary and none of the second, and "kinship", "retrieval", and
  "sweep"
  are this package's internal nouns on top of that.

  So the summary now leads with code similarity search and says what comes back
  (near-duplicate files, clone families, where a snippet came from), with the
  mechanism kept as the differentiator it is: no embeddings, no model, no
  vector
  database. The keywords cover the job, the tools somebody is already using
  when
  they come looking (jscpd, cpd, simian, moss), and the literature terms for
  the
  smaller audience that arrives knowing them (lzjd, ncd, minhash, ziv-merhav).
  The README's h1 says it too, with one line above the origin story so the
  first
  screen is not all etymology.

  The Python binding's README was thirteen lines of contributor notes pointing
  at
  a file path, which would have been the entire PyPI landing page. It is a real
  one now: both kinship questions with worked examples, the retrieval and
  provenance verbs, what `matching` narrowing is for, what the atlas buys, and
  the
  grade bands that keep a background answer from reading as a find. Every
  example
  is checked against the current signatures - `Packed.coverage` is a property
  on
  the object, not on `stats`, which the first draft of this got wrong.
- Docs, doc comments, and test fixtures stopped citing the private monorepo
  this
  was split out of. A reader who lands here cannot resolve `WalletService`,
  `services/backend/api/main.go`, `libs/kernels/…`, or an internal
  decision-record
  number, so every one of those was an example that only worked if you already
  had
  the tree it came from.

  The type name in the `--matching` examples is `SessionStore` now, which
  exercises exactly the same signals; elided paths read `lib/…/scan.py`; the
  markup-weaving test asks its question with neutral `web/app/…` paths, since
  only
  the extension was ever load-bearing there; and the license boilerplate a
  retrieval test uses to prove zero-bit fingerprints names a fictional company
  rather than a real one. The decision-record citations in the changelog are
  gone,
  replaced by what was decided where the sentence needed it, because a bare
  `ADR-367` points at a document nobody outside can read.

  Nothing under `bench/` changed except path plumbing. The benchmark queries
  are
  chosen against a specific corpus, and swapping a high-match pattern for a
  neutral one would quietly turn a measured race into a zero-match one.
- Eighteen READMEs carried a `doc_radar:` block - YAML frontmatter on most, an
  HTML comment on the rest - declaring path, count, and sentinel assertions for
  a
  freshness gate that lives in the monorepo this package was split out of. That
  gate was never ported here, so every one of those blocks was inert. On
  `bindings/python/relate/README.md` it was also the first thing a PyPI reader
  would meet, where the renderer turns a YAML preamble into a horizontal rule
  followed by a heading made of raw YAML. They are gone, and the prose below
  each
  is untouched.
- Every package index this project publishes to now shows the repository's own
  `README.md` as the project's page, rather than the short one kept beside each
  binding. PyPI and crates.io are where most people meet this project first,
  and
  they were being shown a page about the Python binding's verbs - not
  compression-as-search, or the two questions the package exists to answer.

  The README could not simply be pointed at, because a relative link resolves
  against whatever page displays it. `src/surface/face/README.md` is correct on
  GitHub and a 404
  under `pypi.org/project/relate-search/`. crates.io is the worse of the two:
  it rewrites
  relative links against the crate's own subdirectory, so the same path becomes
  a
  well-formed URL into `bindings/rust/` pointing at a file that was never
  there,
  and nothing looks broken.

  So `tools/registry_readme.py` is now the one rewriter both ends share. It
  absolutizes every relative target against the `repository` URL the manifest
  already declares, in the form that serves what the target is - `raw` for an
  image, `tree` or `blob` chosen by what the path is on disk - and a target the
  repository does not contain fails the build instead of publishing a dead
  link.
  GitHub's `> [!NOTE]` alert, which renders as literal text anywhere else, is
  lowered to a bold lead line. Headings need no help: both renderers rewrite
  in-document anchors to match the ids they mint, so the table of contents
  arrives
  intact.

  Python gets it through a Hatchling metadata hook, so the corrected page
  exists
  only inside the artifact. Cargo has no metadata hook, so `readme` now points
  at
  a gitignored `bindings/rust/PROJECT_README.md` that the same tool mints at
  package time - `cargo package` fails loudly if it was never generated, and
  `cargo build` never reads it. Both indexes end up with a byte-identical page.

  An sdist is the one artifact with no repository above it, so it carries the
  corrected README beside the sources and a source build reads that, rather
  than
  being asked for a file the archive does not contain.

  Go needed no rewriting - pkg.go.dev renders the README at the module root and
  resolves its links against the repository - but a dead one there is still a
  dead
  link on the module's landing page, and a Go module has no build step to catch
  it. `--check` now proves those targets resolve too, on every commit.

  The README stays written for the repository it lives in.
- Four docs cited `.local/spikes/…` dossiers from the private monorepo this was
  split out of. Two of those dossiers no longer exist anywhere, so the
  citations
  were pointing at evidence nobody can read - including us.

  Where the citation was only provenance, it is gone and the sentence stands on
  its own: `bench/bounds/codex/README.md` says the codex graduated from an
  early
  rung-1 prototype without naming a directory you cannot open. Where the
  citation
  carried a verdict - the compression-versus-embeddings KILL in
  `research/relate/PRIOR_ART.md`, `research/relate/TESTING.md`, and
  `bench/conformance/relate/README.md` - the verdict stays and the docs now say
  plainly that its write-up never shipped here, so the numbers behind it are
  not
  in this repo. What is in the repo is `bench/conformance/relate/knn.zig`, the
  harness that produced them; the race re-runs against a labeled manifest.

  No measurement, benchmark value, or claim was invented to fill the gap. A
  summary of a spike nobody can still read would be fiction with a citation
  stapled to it, which is worse than an honest gap. `.local/` stays this repo's
  scratch convention; only the vanished-spike citations changed.
- The FM-index and its persisted shelf moved down into `irregex`.

  They were here because the cento quoter consumes them, but gist's `codex`
  verb needs the shelf without wanting the rest of relate — and once the
  relate face also needs gist's answer keep, that is a cycle. The index is an
  index tier; it belongs with irregex's other index tiers and the succinct
  floors already there. What stays is `cento.zig` (the Ziv–Merhav
  corpus-quotation parse), importing the FM-index through `@import("irregex")`.
  `vendor/libsais/` moved with the index.
- The Python binding declared `requires-python = ">=3.14,<3.15"`, which was the
  monorepo's pinned interpreter wearing the costume of a library requirement.
  It is now `>=3.12`, the floor the code actually has (PEP 695 `type` aliases
  in `corpus.py`, and the `irregex` substrate's own floor), with no upper
  bound.

  The lower bound locked out 3.12 and 3.13 for no reason the source supports;
  the binding imports and runs there, which is how the real floor was found.
  The upper bound was the worse half, because it fails in the future: `<3.15`
  turns the day CPython 3.15 ships into the day this package stops resolving.
- The Python distribution is `relate-search`; the import is still `relate`.
  `relate` on PyPI belongs to an unrelated author - a discrete-mathematics
  relation library - so the name was never available to publish under, and,
  worse,
  a plain `pip install relate` fetches that stranger's package into a tree that
  then imports `relate` and gets whatever it contains. Splitting the two names
  closes that: `pip install relate-search`, `import relate`, which is the same
  shape bs4, PIL, and cv2 already ship, and the same split `gist-search` made
  next
  door. Only `[project].name` moved; the package directory, the wheel's
  `packages`
  entry, and every `import relate` in the tree are untouched, so nothing a
  caller
  writes changes.

  The repository also gets a release workflow, which is what forced the
  question.
  It publishes one `py3-none-any` wheel plus a genuinely buildable sdist
  through
  PyPI Trusted Publishing on a `v*` tag, and refuses to publish a tag that does
  not name the declared version. Two gates run before anything leaves: the
  built
  wheel's `Requires-Dist` must resolve from the index, because the
  `[tool.uv.sources]` path that makes a local checkout work never reaches core
  metadata; and the artifact is installed on the declared 3.12 floor from a
  directory that is not the project, so a `requires-python` guess fails here
  rather than at someone's import. The binary is not published - the Zig
  package
  is consumed through a tag's tarball, and the CLI is built from source.
- The codex FM-index now builds its suffix array with **libsais 2.10.2**,
  pinned and compiled from source under `vendor/libsais/`, in place of the
  hand-rolled induced sort. Measured on real repo source, min of 3: the sort
  runs 10.58 s → 3.23 s at 200 MB (3.3×), 6.00 s → 2.02 s at 128 MB, and the
  whole codex build 14.3 s → 7.0 s (2.1×). Correctness is not asserted, it is
  differential: the two constructions were run against each other over the full
  200 MB corpus and agreed on every one of 209,715,201 rows before the old one
  was retired.

  `sais.zig` keeps its exact public contract — one `build(gpa, text)` returning
  `text.len + 1` rows with the sentinel suffix first — and shrinks to the one
  fact that separates the two conventions. libsais sorts the n suffixes of the
  raw bytes; the codex indexes n+1 symbols because it lifts every byte to c+1
  under a unique smallest sentinel, and that sentinel is unconditionally rank
  0, so the answer is `[text.len]` followed by libsais's array unchanged. The
  seam therefore costs a single stored word: libsais sorts straight into the
  tail of the same allocation, and the shipped path measures indistinguishable
  from a bare C call. The suffix sort's `int32_t` indices are now declared as
  `sais.max_text_len` and enforced with a fail-closed `Oversized` rather than
  discovered as a truncated index, and the megabyte-scale differential added
  beside the existing comparison-sort oracle checks the construction where it
  changes strategy, using a linear permutation-and-adjacency oracle a naive
  sort cannot follow to.

  `build.zig` grew a **vendored C floor** to hold both libraries without a
  second copy of the wiring: one declarative row per archive (name, include
  path, sources, feature flags) and a single `Floor.under(module)` that links
  libc plus every archive at that module's own optimize, memoized per mode so
  the modules sharing a mode share one build of it. Admitting a third vendored
  library is now a row, not a call-site sweep.

  What this did _not_ buy is worth recording too. The sort fell from 74% of the
  codex build to 46%, so even a free suffix sort would leave 3.8 s at 200 MB
  before the shelf's ~2 s of concatenation and serialization — `relate index
  --shelf` stays opt-in, and the next pole is the wavelet/RRR construction, not
  suffix sorting.
- The codex shelf's lifecycle — its path, atomic write, fail-closed read, and
  staleness walk — moved down into `corpus/index/shelf/shelf.zig`, where all
  three faces stand. `relate quote`, `relate index --shelf`, and `irregex
  provenance` had been importing the `gist codex` verb module for it, which
  made a change to gist's verbs reach two other products; now each face only
  names its own rebuild command in the failure sentence, through the shared
  `outcome.needArtifact`.
- The shared artifact home moved from `.local/gist-verify/` to `.gist/`, and
  relate's docs and contract now name the new path. `.local` was the monorepo's
  machine-local scratch convention; outside it the directory means nothing, and
  `gist-verify` read like a verification harness rather than where the index,
  kinship atlas, and codex shelf actually live. `.gist` names itself the way
  `.git`, `.ruff_cache`, and `.mypy_cache` do, and it reads correctly against
  the
  `GIST_DIR` override that was always the real knob.

  This orphans whatever you already built. Nothing migrates and nothing is
  deleted; the old directory just stops being consulted, so the first query
  after
  this lands answers live instead of warm. Regenerating is cheap - `gist index`
  is
  about 3 seconds and `relate index` about 4 on a full tree - and if you would
  rather not, `GIST_DIR=.local/gist-verify` pins the old location and
  everything
  keeps reading out of it.

  `contract/kinship.toml` declares the atlas and fragment artifacts at the new
  path, and `.gist/` is gitignored here alongside it.
- The substrate this library links is now `libirgx`, and the status codes its
  header quotes are `IRGX_*`. Nothing about relate's own surface moved: the
  artifact is still `librelate`, the header is still `include/relate.h`, and
  `relate_run` and the `RELATE_OP_*` codes are untouched. What changed is the
  spelling of the engine underneath - a C caller now writes `-lrelate -lirgx`
  against `<irgx.h>` and reads `IRGX_OK` / `IRGX_STALE` / `IRGX_INVALID` back,
  instead of including one name and linking another. The cgo tier's `LDFLAGS`,
  the build graph's `artifact("irgx")` lookup, and the packaging test that
  stages
  both libraries into one directory all follow the file to its new name; the
  Zig
  package is still `@import("irregex")` and the engine's repo, crate, and
  module
  path are all still `irregex`, because those name the project rather than the
  thing you type. This lands before v1.0.0 on purpose - v1 freezes the linker
  name the same way it freezes the symbol prefix, so this was the last free
  window.
- This package no longer depends on `_buildkit`, a sibling that existed on one
  machine and had no remote. It borrowed one file from it — `brigade.zig`, the
  shard-aware test runner — which now lives in `irregex` and is reached through
  the dependency on `irregex` this build already declares. One fewer edge in
  the graph, and one fewer unpublished repository standing between a clone and
  a test run.

  Two doc comments pointed at a `_buildkit/build.zig` helper that is no longer
  reachable from any of these repositories; they now describe the fan-out this
  build actually performs.
- `relate` had ten verbs standing for what turned out to be two questions asked
  at different settings. It now asks those two, and the settings are flags.

  **A verb per corner of a product space.** `dups`, `clusters`, and `concepts`
  were three names for one survey — "what repeats?" — frozen at three points of
  a cube whose axes are the comparison _unit_ (a whole file or one extracted
  function), the _channel_ that decides what "same" means, and the _shape_ of
  the answer (pairs, families, or the complement). Each verb reached exactly
  one corner and could reach no other: there was no way to ask for
  byte-duplicate _functions_, or the structural families of _files_, or which
  units are genuinely unique, because no one had minted a name for those
  corners. Meanwhile `similar` and `search` were one question — "what is near
  this probe?" — split by the _type of the probe_ rather than by the question,
  so a caller had to know which verb owned paths and which owned text before
  they could ask. `similar` and `echoes` were also, by the tool's own
  measurement, the second-widest structural echo in the face directory (0.218
  apart in bytes, near-identical in shape): the same
  score-sort-grade-emit-report flow written twice.

  **Two questions, three axes, one flag each.** `relate similar <probe>`
  answers "what is near _this_ one?" and `relate echoes` answers "what repeats
  among _all_ of them?" Everything the retired verbs spelled as a name is now
  `--unit file|function`, `--as copies|twins|shapes|any`, and `--shape
  pairs|families|distinct` — which means the corners nobody had minted a name
  for are now reachable by composition. `relate echoes --unit function --as
  copies --shape families` finds a helper pasted into five files, which
  file-level kinship structurally _cannot_ see, because the shared helper is a
  few percent of either file's bytes. `--shape distinct` returns the complement
  of the families with each row's nearest miss attached, so "this is genuinely
  unique" becomes an answer with a receipt rather than an absence.

  **The probe's shape picks the pricing, so the caller doesn't have to.**
  `similar` reads what it was handed: an existing path is priced by kinship
  distance; `path#L340` resolves the function containing line 340 and compares
  functions rather than their containers; free text is priced by coding gain
  against the corpus, which is what `search` was. Coding gain needed its own
  calibration to be reported honestly — it rises where a distance falls, and a
  one-word query is cheap to explain anywhere, so `identical` ≥ 0.90 (the
  corpus quotes the probe back verbatim) · `strong` ≥ 0.60 · `moderate` ≥ 0.45
  · `weak` ≥ 0.30 keeps `def` at 0.43 reading as "not really here" instead of
  as a hit. A fragment probe also defaults to `--as shapes` without being told,
  because the fragment atlas persists silhouettes and not byte sketches: the
  default follows what the index can actually answer warm.

  **Narrowing was a modifier wearing a verb's clothes.** `irregex context` and
  `irregex family` each froze one point of the same space, plus an exact
  pre-filter. Composition is now `--matching PAT` on `similar`, `echoes`, and
  `pack` — so it combines with every other axis those verbs carry, which a
  composed verb per corner never could. `relate echoes --matching SessionStore
  --unit function --shape families` was previously unaskable. The composition
  _kernels_ are unchanged (exact-before-statistical composition stands; only
  its surface claim is amended): exact still narrows the population before any
  statistics run, the exact and statistical scores still occupy separate
  fields, and the noise floors are now calibrated against the matching set
  rather than the corpus. The `irregex` binary keeps exactly the two questions
  that need the tree's _current bytes_ rather than a narrowing — `provenance`
  and `blast` — which is the coherent identity the original three-verb grouping
  obscured.

  **Retiring a name is a teaching moment, not an error.** Every folded spelling
  exits 2 with its new invocation on stderr, including across binaries:
  `irregex family` prints `relate echoes --matching PAT`. The retirements are
  rows in the same `Face` table the help and `--schema` derive from, so a
  folded verb appears in `--help` and in the JSON manifest with the full
  runnable command — an agent that learned the old vocabulary is corrected by
  the tool rather than left guessing.

  **Dogfooding the fold found two real bugs in the machinery it was built on.**
  Running `echoes --unit function --shape families` over the live tree reported
  one unit thirteen times in a single family. The cause was function-span
  extraction: a multi-line data literal with parentheses in its prose satisfied
  the "function header" heuristic, and consecutive braces on one logical line
  re-anchored to the same start offset, so one region was emitted repeatedly.
  Both are fixed at the source in `kernel/compose/spans.zig` with regression
  tests. Separately, `similar --as shapes` returned "no kin" on files that
  visibly had structural twins: the mass floor that keeps a fingerprint-poor
  file from producing a spurious 0.0 distance was calibrated for LZJD sketches
  (16 min-hashes) but was being applied to silhouettes, which are a sparser
  record. The floor now follows the _channel's record_ rather than the unit's
  container — 16 for bytes, 8 for structure, and a channel that reads both
  (`twins`, `any`) requires mass in both — which is the rule that was always
  intended and never stated.
- `relate` ships its own CLI now.

  The face and the CLI vocabulary (`flags` · `grade` · `manifest` ·
  `reprise`) moved here from the `gist` package, where they had lived only
  because an earlier cycle forced the binary into the product chassis. The
  FM-index shelf's move into `irregex` broke that cycle; this finishes the
  split. `zig build` produces a `relate` binary. The face dials gist's
  resident daemon for the answer keep (`@import("gist")`), so a recalled
  sweep still turns a 27-second question into milliseconds — the dependency
  points the right way now.

### Fixed

- Every function in this package is annotated, public and private alike, and
  every consumer's type checker has been ignoring all of it. PEP 561 says
  annotations inside an installed package are invisible unless the package
  ships a `py.typed` marker, and this one never did. The work was done and then
  hidden: `mypy` run against code importing this package got `Any` for the
  whole API and reported nothing wrong.

  The marker is there now, and hatchling ships it because it sits inside the
  package directory. There is a test for it too, because the failure mode is
  silent in both directions - nothing here breaks when it goes missing, and
  nobody downstream is told.
- Every workflow checkout of a sibling package now carries `token: ${{
  secrets.ECOSYSTEM_TOKEN || github.token }}`, matching the pattern `blast`
  already used. The default `GITHUB_TOKEN` is scoped to the repository running
  the job, so a checkout of a *private* sibling 404s on a runner no matter how
  correct the rest of the job is; eight checkouts across this repo's jobs pull
  `irregex` and `gist`, and both are private. The fallback is what makes this
  safe to land ahead of the secret: with no `ECOSYSTEM_TOKEN` configured the
  expression collapses to the default token and the behavior is exactly what it
  was, so a fork still fetches whatever is public and gets a legible 404 on
  whatever is not, rather than a mystery failure inside a build step. This is
  wiring, not a grant; the secret itself does not exist on any of the four
  repositories or at the organization level yet, so the private-sibling
  checkouts stay red until someone creates it or the sibling goes public.
- The Go kinship suite built its corpus in a temp directory but let the
  **artifact home** come from the ambient environment, so a developer with
  `GIST_DIR` exported had every one of these tests answering out of some other
  tree's atlas. That reads as `recall found nothing for text lifted out of the
  corpus itself` — a failing assertion about kinship — rather than as a
  misconfigured run.

  The fixture now gives each corpus its own artifact home. A temp corpus is
  only hermetic if its artifacts are too; the suite passes with `GIST_DIR` set
  and unset alike, instead of requiring the caller to remember to unset it.

  Module floor lowered to `go 1.24` alongside irregex: the `new(0.6)` sugar
  that had forced `go 1.26.3` was test-only.
- The Python job checked the substrate out and never built it, so every module
  died during collection on its first `from irgx.contract import …`: an in-tree
  checkout ships no bundled library and resolves the one `zig build` leaves
  under `zig-out/lib`. It builds irregex now, and gist too, because the kinship
  suite reaches its corpus through `gist.files` / `gist.search` and the skip
  guard there only asks whether `relate` resolves - so a missing gist was a
  failure rather than a skip, which is the right verdict and means the binary
  has to be present.
- The Rust integration suite could report a clean pass having run nothing. Each
  of
  its five tests opened by probing for a `relate` binary and returning early
  when
  it found none — and Rust's stable harness has no conditional skip, so an
  early
  return is indistinguishable from a completed test. With no binary reachable
  the
  suite printed `5 passed` in 0.00s, which is the one result CI must never be
  able
  to produce quietly: a green tick over an untested seam.

  The probe is now a precondition that fails instead of returning, naming the
  binary it looked for, what went wrong, and the two ways to fix it (`zig
  build`,
  or point `RELATE_BIN` at one). This is the line the exact face's suite
  already
  holds — "do not Skip (test-bandaid)" — and integration tests whose stated
  purpose is to run the real thing are exactly where it belongs. With the
  binary
  present the five still pass, in 0.02s of actual work rather than 0.00s of
  none.
- The Rust integration suite failed all five of its tests in a clean checkout,
  and the engine it could not find was sitting in this repository's own
  `zig-out/bin`.

  The precondition that replaced the old silent early-return was right to fail
  loud, but it looked for the binary itself - a bare `Command::new("relate")`,
  which is a `PATH` lookup and nothing else. Everything it then went on to test
  resolves through `irregex::runtime::shell`, which walks the checkout first.
  So
  the guard and the code under test were asking different questions, and on a
  machine with no globally installed `relate` the guard answered no while the
  library would have answered yes. A test whose whole point is to drive the
  real
  engine was refusing to drive an engine that was right there.

  It routes through `binary_named` now - the same ladder the library uses,
  which
  also means the guard's `--schema` probe runs the exact binary the tests will
  drive rather than a second one that happened to be installed. Five tests,
  five
  passes, no `relate` on `PATH`.

  The Go suite got the same treatment from the other direction: seven of its
  eight
  tests opened with a `requireEngine` helper that skipped when discovery came
  back
  empty. That is the shape that lets a package report `ok` having exercised
  nothing. A `TestMain` resolves the engine once and fails the package if it
  cannot, so the seven assert rather than guard, and the helper is gone.
- The blast kernel resolved every hit to its enclosing function and dropped the
  ones that had none. Registries, dispatch tables, export lists, struct
  literals, top-level `const` wiring - all invisible, and those are usually the
  first thing an edit breaks. Dogfooding it on its own dispatcher found the
  definition, missed the one line that actually calls it, and listed the
  definition as its own dependent.

  The pass is now a single walk that keeps every hit and says what each one is.
  A reference at file scope is a dependent with no enclosing name rather than a
  dropped row, the seed's own definition is excluded from its dependents, and
  each row carries whether it defines, whether it sits in a string literal, and
  whether its file is generated.

  A mention in a file that cannot declare anything - a README, a changelog, a
  spec table - used to vanish rather than report, because the lexer found no
  comment syntax to put it in. Those are now mentions like any other, since a
  rename falsifies a documented name exactly the way it falsifies a doc
  comment.

  Rows sort by what an agent should read first: authored code, then authored
  strings, then generated code, then generated strings. A budget that trims the
  tail now trims codegen, not the one hand-written call site. `no definition
  site found` also stops implying the symbol is external when the likelier
  answer is that you scoped the search past it.
- The compression-vs-embeddings rung told you to go looking for it in the wrong
  place, three different ways. Two docs cited the harness as
  `bench/knn/knn.zig`,
  a path that has not existed since the rung moved under
  `bench/conformance/relate/`. Worse, `TESTING.md` opened its reproduction
  block
  with `cd ../gist`, on the theory that the harness lived in the product
  chassis
  next door — but `relate-knn` is wired into this package's own `build.zig`,
  and
  `gist` has no such step, so following the instructions landed you in a repo
  where the command does not exist.

  The paths now name the real file and the block runs from this repo root.
  While
  proving the step was here, the other half of the problem surfaced:
  `relate-knn`
  takes a dataset directory holding a `manifest.tsv`, and the driver that wrote
  that manifest went with the prototype race whose write-up already didn't
  ship.
  The harness is real and the lanes it prices are real; what is missing is the
  labeled corpus and the few lines that lay it out. Both docs now say so,
  because
  "the harness is, so it stays re-runnable" reads as *clone and run it*, and
  that
  is a promise this package cannot currently keep.
- The declared dependency is `irregex>=1.0.0,<2` instead of a bare `irregex`.

  Unbounded, that resolves to `irregex==0.1.0` - the pre-rename placeholder on
  the index, which has no `irgx` module in it at all, so an install would
  succeed and then fail on the first import. The floor is 1.0.0 because that is
  where `irgx` starts existing; the ceiling is the same fact from the other
  side, since 1.0.0 is where the substrate froze the C ABI and the `irgx`
  surface and a 2.0 is free to move both. This is a face over an ABI, not a
  consumer of a loose utility.
- The packaging suite asked whether librelate had absorbed the engine by
  deleting libirgx from a staging directory and requiring the load to fail.
  That is a proxy for a question about symbols, and it answered differently per
  machine: Zig records the dependency's build-cache directory as a search path,
  and where `ZIG_LOCAL_CACHE_DIR` is absolute the loader resolves the deleted
  library straight back out of the cache. So the gate held on a dev machine and
  asserted nothing on CI. It reads the export table now, which is what "does
  not redefine `irgx_*`" actually means, and a companion case runs the same
  probe over both libraries so an empty answer cannot pass for a clean one. A
  third case pins the loader-relative search path that makes the shipped shape
  loadable, which a build-cache path that happened to resolve used to hide.

  What it deliberately does not assert is that librelate records libirgx as a
  needed dependency. That record is the linker's decision rather than this
  repository's: ELF drops an `--as-needed` library that no undefined symbol
  needs, so a product whose statically linked Zig already satisfies everything
  records nothing, while Mach-O keeps the entry regardless. The sibling
  products disagree on exactly that line from identical link calls. Absent
  redefinition is what makes the engine vocabulary single; the dependency table
  only ever explained it, so it is reported in the failure message rather than
  gated.
- The split moved the product face and the measurement lanes into this package,
  and a handful of docs kept describing the arrangement from before it. The
  research map was the worst of them: its code table put the face at
  `../gist/src/surface/face/relate/`, a directory that no longer exists, and
  its
  Run block opened by telling you the CLIs ship from the gist sibling. They do
  not - `zig build` here installs `relate`, and has since the CLI came home.
  Two
  of its freshness assertions pointed at the same dead path, so they could only
  have gone on passing by never being checked.

  The reproduction blocks were wrong in a quieter way. Both the knn README and
  `TESTING.md` opened with a plain `zig build` and claimed it minted
  `zig-out/bin/relate-knn`; it does not, because the lab lanes deliberately sit
  off the default install step, so a bare build installs the product binary and
  nothing else. `zig build relate-knn` does not fill the gap either - that step
  *runs* the harness, so with no dataset it exits 1. Both now say `zig build
  lab`
  and say why.

  The evidence table in the root README cited three gates by bare filename -
  `patterns_test.zig`, `trawl_test.zig`,
  `bench/gates/patterns_corpus_parity.sh` -
  and none of the three resolves inside this repo: the N-pattern slate is the
  library's and the corpus-parity gate is the product chassis's. They are named
  with their owning package now, and the row that called the knn race a
  "rerunnable comparative harness" says what the other two docs already say -
  the harness ships, the labeled corpus does not.

  Also swept: the codex README asserted `build.zig` compiles libsais, which
  this
  package has never done (it rides in with the library), `race.sh` gave its own
  path as `bench/codex/race.sh` two directories short, and the Rust tests
  README
  still advertised the skip-when-missing behavior that was removed for
  reporting
  `ok` over nothing. No command, path, or number was invented - each one was
  run
  or resolved on disk first.
- The test runner is pinned by url and hash instead of assumed to sit beside
  this
  repository.

  `.brigade = .{ .path = "../brigade" }` resolves on a machine that happens to
  have
  the sibling checked out, and nowhere else - so a fresh clone, and CI, could
  not
  build this package at all. brigade is a published package now
  (github.com/The-Billy-Company/brigade), pinned the way the vendored engines
  already were.

  The co-developed siblings stay path deps on purpose: those change together
  with
  this repository and a checkout beside it is the point. A test runner does
  not,
  so this repository chooses its version deliberately.
- `librelate.a` resolves its substrate symbols through libirgx rather than
  redefining them, so a static consumer links the pair - and the install prefix
  only ever held one half of it. `libirgx.so` was installed, `libirgx.a` was
  not,
  so anyone following the archive path had to go find the engine's archive in
  another checkout and hope it was built for the same target.

  It installs now, taken off the dependency graph as a named lazy path rather
  than copied from a sibling `zig-out`, so it is the right target and the right
  optimize mode by construction.

  The ELF `librelate.a` also stops registering a second build artifact named
  `relate`. The dylib already owns that name, and a duplicate makes a
  dependent's
  `dep.artifact("relate")` ambiguous enough to panic the build runner - in the
  DEPENDENT, never here, and only on the arm macOS does not take. Both arms
  install the archive as a file now, the way the macOS arm already did for its
  own alignment reasons.
- `librelate` was not loadable outside the tree that built it. Linking the
  substrate records the dependency's own build output directory as an rpath,
  and that path is a *relative* `.zig-cache/o/<hash>` — true on the machine
  that produced it, meaningless anywhere else — so a consumer's
  `dlopen("librelate.dylib")` failed with `Library not loaded:
  @rpath/libirgx.dylib` before a single call reached the engine. `build.zig`
  now adds a loader-relative rpath (`@loader_path`, `$ORIGIN` off macOS),
  making the shape we actually ship — every library in one lib directory — the
  loadable one.

  This hid behind the bindings, which load the substrate first: once `libirgx`
  is in the process, the loader satisfies a later `@rpath` reference from the
  already-loaded image by install name. Every binding worked; only an honest
  standalone consumer failed, which is the one case nothing tested.

  `tests/test_packaging.py` now stages both libraries into a directory and
  opens the product in a child process with a clean environment, from an
  unrelated working directory — a same-process check would inherit exactly the
  rescue that hid this. Mutation-proven by deleting the rpath from the built
  dylib; a sibling test asserts the complement, that removing the substrate
  still breaks the load.
- `refAllDecls` reaches a struct's declarations without analyzing the files
  behind them, so it goes exactly one level deep. Every `kernel/compose` module
  keeps its tests in-file rather than in a `_test.zig` sibling, which put all
  of them below that line: `blast`, `regions`, `context`, `family`, and
  `provenance` compiled in the suite and ran none of their assertions.

  They are named outright in the root test block now, the way the `_test.zig`
  siblings already were. All of them pass, so nothing was hiding - but nothing
  was proving it either, and a green suite that skips a kernel is worse than a
  red one.
- `relate --version` said `1.0.0`. relate was `0.1.0`. It was printing the
  engine's semver, because that was the only version in reach that nobody had
  to hand-maintain - the manifest module's own comment records the earlier
  shape of this bug, where both faces hardcoded `0.1.0` against an engine at
  `0.2.0`.

  Now `build.zig` lifts `.version` out of `build.zig.zon` as a build option and
  `src/root.zig` exposes it, so `--version` and the `--schema` manifest report
  this package's number, read from the one place it is written and restated
  nowhere. The engine stays askable through
  `@import("irregex").version_string`; it is a different axis on a different
  schedule, which is exactly why borrowing it was wrong.

  `Cargo.toml` and `pyproject.toml` keep a copy because neither can import
  anything, both marked with `x-release-please-version` and both listed in the
  new `release-please-config.json`, so one merged release PR moves all three
  together. `tools/version_parity.py` fails if a copy drifts or if a marked
  line was never declared to the bot, and runs in CI as the `version` job.
- `src/kernel/codex/cento_test.zig` ended with a blank line after its closing
  brace, left behind when the CLI moved into this repository. It had been
  sitting
  in `main` unnoticed, which is the entire argument for the formatter gate
  landing
  alongside it — nobody was ever going to catch a trailing newline by reading.

  Whitespace only, and checked rather than assumed: the file's bytes with all
  whitespace stripped hash identically before and after, and the three `cento`
  tests pass on both sides of the change.

## [0.2.0] - 2026-07-24

### Added

- A persisted **kinship atlas** (`src/index/atlas/`) gives `relate` its own
  warm tier: `relate index` snapshots every corpus file's LZJD sketch (plus
  path table, wall-clock anchor, FNV-1a checksum) atomically to
  `.gist/kinship.atlas`, and `relate status` reports readiness,
  freshness, and staleness for both the atlas and the optional codex shelf
  (`relate index --shelf` now builds the quote shelf without shelling out to
  gist). The sketch verbs (`similar`/`dups`/`clusters`) load the atlas and fold
  in only files changed since the anchor — re-sketched from live bytes,
  deletions gated out — so warm answers are byte-identical to a cold rebuild,
  just ~12× faster (95 ms vs 1.2 s for `similar` over the 22.8k-file live
  corpus); `--no-index` or a missing atlas falls back to the live build with
  identical output.
- Add research/relate/ dossier (CLAIM + PRIOR_ART + TESTING) matching
  crest/gist: Language Trees and Zipping lineage, 3Blue1Brown cross-entropy
  video, and every citation the shipped engines actually use.
- New `irregex` binary — the composed third face over the one kernel:
  the exact engine narrows a typed `CandidateSet`, then the compression engine
  reasons only inside that subset, so an exact intent scopes the statistical
  one
  instead of a caller unioning two independent queries by hand. Three closed
  verbs: `context TEXT -e P…` (coverage packing over only the files that match
  the patterns — each pick carries its exact mask AND its marginal bits, never
  a
  fused score), `family PATTERN {--max-distance | --echo-min}` (fork families —
  byte near-duplicates or renamed structural twins — among only the matching
  files), and `provenance TEXT` (quote attribution re-verified against each
  source's CURRENT bytes, so a phrase surfaces only if the live file still
  holds
  it — never a stale line). `context`/`family` require an explicit scope
  (`ROOT…` or `--all`); results on stdout (`--json` = NDJSON), diagnostics on
  stderr, unknown verbs exit 2. The pure composition kernels live under
  `src/search/compose/`; `gist` and `relate` stay the direct faces and forward
  none of their verbs. Installed alongside them.
- The `compose` tier gains a sibling contract differential for its
  typed `CandidateSet`: `candidates_test.zig` proves `select` equals the plain
  set-algebra of N independent single-pattern substring runs — union under
  `.any`, intersection under `.all`, with exact per-pattern masks — against an
  engine-independent `std.mem.indexOf` oracle over a randomized 260-doc corpus,
  plus overlapping-literal attribution, the 64-pattern bit-63 boundary, and the
  empty / over-cap error paths. The kernel is now wired into the merge-blocking
  CI test fan-out, running `zig build test` + `zig
  build -Doptimize=ReleaseFast` in the shared Go-cgo + pinned-Zig base, so a
  regression in the search kernel now fails a PR rather than only a local run.
  The twelve remaining 500+ line modules
  (json/query/classrun/shadow/analysis/persist/fresh/protocol/watch/render/blast/regions)
  carry honest file-length markers with recorded reasons, closing the
  shape-discipline debt.
- `relate search <text>` — compression-as-search retrieval, hand-rolled. The
  relate engine gained two modules under `src/search/similarity/`:
  `lexicon.zig`, a
  corpus-priced fingerprint index (winnowed 8-gram fingerprints à la MOSS,
  priced at their corpus information content −log2(df/N) bits — boilerplate is
  worth exactly 0), and `zipper.zig`, a per-candidate suffix automaton driving
  an exact Ziv–Merhav cross-parse (the "Language Trees and Zipping" ΔAb
  computed in closed form — no compressor run, no entropy coder). `retrieve`
  composes them: the lexicon nominates, the zipper decides; the score surfaced
  is coding gain ∈ [0,1]. The first LZ78-phrase draft was measured misranking
  short queries to parse-boundary noise and replaced. Proven by an adversarial
  fixture suite (short-query recall where the symmetric LZJD sketch provably
  collapses, ΔAb sidedness/asymmetry, zero-bit boilerplate, determinism) and
  `bench/races/relate_headtohead.sh` — paraphrase queries gist answers with 0
  hits, planted-source top-1 as a hard gate, ~2x one-pass speedup over the
  K-token gist emulation.
  (see also: gist)
- `src/index/codex/` — the compressed self-index: an FM-index (SA-IS suffix
  array →
  BWT → canonical-Huffman wavelet tree over RRR-compressed bitvectors) that
  holds a corpus at entropy-bound size while answering `count(P)` in O(|P|)
  flat in corpus size, `find` at a tunable sampling stride, and `restore()` —
  the entire original text, byte-exact, from the index alone. Differential +
  property tests against naive oracles at every layer; `zig build codex-scale`
  (+ `bench/codex/race.sh`) proves space/time/decodability on ~187MB of real
  repo source against gzip/bzip2/zstd/xz.

### Changed

- (in `gist`) Scrubbed the last project-specific hardcoding out of the kernel for OSS-clean…
- The `relate` warm retrieval session (`recall.zig`) now guards its
  `search`/`pack` with the shared `Ward` reader/writer primitive instead of a
  plain `Io.Mutex`, so concurrent relate queries overlap under a shared lease
  on the watcher-clean fast path (only an overlay recompute takes the exclusive
  lease) — the same reader-overlap gist queries already had. Read safety is
  sound because the retrieval lane is read-only over the session's
  `persisted`/`fresh_ids`.

### Fixed

- (in `irregex`) Reconciled the C-ABI compatibility integer so every axis agrees on the…
