# Changelog

All notable changes to `relate` (the similarity engine) are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versions track
`build.zig.zon`.

<!-- towncrier release notes start -->

## [0.2.0] - 2026-07-24

### Added

- A persisted **kinship atlas** (`src/index/atlas/`) gives `relate` its own
  warm tier: `relate index` snapshots every corpus file's LZJD sketch (plus
  path table, wall-clock anchor, FNV-1a checksum) atomically to
  `.local/gist-verify/kinship.atlas`, and `relate status` reports readiness,
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
- New `irregex` binary — the composed third face (ADR-367) over the one kernel:
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
  none of their verbs. Installed alongside them by `make install-gist`.
- The `compose` tier (ADR-367) gains a sibling contract differential for its
  typed `CandidateSet`: `candidates_test.zig` proves `select` equals the plain
  set-algebra of N independent single-pattern substring runs — union under
  `.any`, intersection under `.all`, with exact per-pattern masks — against an
  engine-independent `std.mem.indexOf` oracle over a randomized 260-doc corpus,
  plus overlapping-literal attribution, the 64-pattern bit-63 boundary, and the
  empty / over-cap error paths. The kernel is now wired into the merge-blocking
  CI test fan-out as `TestGist` (an internal `TestResultsAll` leg beside
  `TestBillog`/`TestPrincipia`/`TestLamina`), running `zig build test` + `zig
  build -Doptimize=ReleaseFast` in the shared Go-cgo + pinned-Zig base, so a
  regression in the search kernel now fails a PR rather than only a local run.
  The twelve remaining 500+ line modules
  (json/query/classrun/shadow/analysis/persist/fresh/protocol/watch/render/blast/regions)
  carry honest `MONOLITHIC` markers + registry rows, closing the
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
