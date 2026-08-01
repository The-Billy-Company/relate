---
doc_radar:
  paths_exist:
    - ../gist/src/surface/face/relate/main.zig
    - src/kernel/kinship/recall/zipper.zig
    - src/kernel/kinship/recall/lexicon.zig
    - bench/conformance/relate/knn.zig
  sentinels:
    - file: src/kernel/kinship/metric/sketch.zig
      contains:
        - "Language Trees and Zipping"
        - "LZJD"
    - file: ../gist/src/surface/face/relate/repertoire.zig
      contains: ["\"search\"", "\"pack\"", "\"quote\"", "\"similar\"", "\"dups\"", "\"clusters\"", "\"echoes\"", "\"concepts\"", "\"patterns\""]
    - file: contract/kinship.toml
      contains: "[verbs]"
---

# Relate — research map for compression-as-search

Relate studies the questions before exact search has a name to match: **what
shares information, which sources add distinct context, and where has this
text appeared before?** It turns compression kinship into agent-shaped
answers—ranked files, complementary packs, fork families, structural echoes,
and attributed corpus quotations—without a model or per-language parser.

The spark is Benedetto, Caglioti & Loreto's _Language Trees and Zipping_
(Phys. Rev. Lett. 2002): two texts are close when one compresses well against
the other's dictionary. Relate graduates that compressor-defined relative
entropy into exact cross-parses, sketches, and a priced fingerprint lexicon
for coding agents.

The research claim is the resulting **systems/workload composition**, not
ownership of compression mathematics. Product thesis, ancestry, and evidence
remain separate so each can be challenged on its own terms. The kernel's
stronger novel-math claim lives on the Gist side in the Crest sieve
(`irregex/research/crest/`).

## This folder (research: writing + scope only)

| file                           | research role                                                                                                                                  |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| [`CLAIM.md`](CLAIM.md)         | the positive product thesis: compression as search, the answer objects agents receive, the engine behind them, and the composition claim       |
| [`PRIOR_ART.md`](PRIOR_ART.md) | the lineage actually used—Language Trees, LZJD, winnowing, Ziv–Merhav, FM-indexes, and submodular selection—plus measured neighboring families |
| [`TESTING.md`](TESTING.md)     | the falsification record: exactness gates, kinship evaluations, compression-vs-embeddings race, warm-atlas identity, and reproduction commands |

## The code (lives with the system, not here)

| where                      | what                                                                           |
| -------------------------- | ------------------------------------------------------------------------------ |
| `../gist/src/surface/face/relate/` | product face (query verbs + lifecycle + schema; ships the `relate` binary) |
| `src/kernel/kinship/`      | sketch (LZJD) · silhouette (structure) · lexicon (recall) · zipper (exact ΔAb) |
| `../irregex/src/kernel/slate/` | `patterns` / loom (N-pattern exact attribution; lives in the library)       |
| `src/corpus/index/atlas/`  | persisted kinship atlas (warm `similar`/`dups`/`clusters`/`echoes`)            |
| `src/kernel/codex/` + `src/corpus/index/shelf/` | FM-index math + persisted SHLF behind `quote` (shared with `gist codex`) |
| `bench/conformance/relate/` | compression-vs-embeddings knn harness (built via gist: `zig build relate-knn`) |

## Run

```bash
# product CLIs ship from the gist sibling: `zig build` there installs
# `relate` beside `gist` onto zig-out/bin/
relate similar path/to/file --top 5
relate pack "how does CDC recover?" --top 8
relate quote 'a pasted snippet'
relate index --shelf                   # kinship atlas + codex shelf
relate status --json
zig build test                         # this package's engine suite
# knn harness: see TESTING.md (built from the gist sibling)
```

## Status

**Shipped.** Dogfooded for similarity, duplication, context packing, and
provenance. Start with the positive case in
[`CLAIM.md`](CLAIM.md), audit its ancestry in
[`PRIOR_ART.md`](PRIOR_ART.md), then test every assertion against
[`TESTING.md`](TESTING.md). The operational product face lives in
`gist/src/surface/face/relate/README.md`.
