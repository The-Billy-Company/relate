---
doc_radar:
  paths_exist:
    - libs/kernels/irregex/src/surface/face/relate/main.zig
    - libs/kernels/irregex/src/kernel/kinship/recall/zipper.zig
    - libs/kernels/irregex/src/kernel/kinship/recall/lexicon.zig
    - libs/kernels/irregex/bench/relate/knn.zig
  sentinels:
    - file: libs/kernels/irregex/src/kernel/kinship/metric/sketch.zig
      contains:
        - "Language Trees and Zipping"
        - "LZJD"
    - file: libs/kernels/irregex/src/surface/face/relate/repertoire.zig
      contains: ["\"search\"", "\"pack\"", "\"quote\"", "\"similar\"", "\"dups\"", "\"clusters\"", "\"echoes\"", "\"concepts\"", "\"patterns\""]
    - file: libs/kernels/irregex/contract/search_api.toml
      contains: "[irregex.verbs]"
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
([`../crest/`](../crest/PROOF.md)).

## This folder (research: writing + scope only)

| file                           | research role                                                                                                                                  |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| [`CLAIM.md`](CLAIM.md)         | the positive product thesis: compression as search, the answer objects agents receive, the engine behind them, and the composition claim       |
| [`PRIOR_ART.md`](PRIOR_ART.md) | the lineage actually used—Language Trees, LZJD, winnowing, Ziv–Merhav, FM-indexes, and submodular selection—plus measured neighboring families |
| [`TESTING.md`](TESTING.md)     | the falsification record: exactness gates, kinship evaluations, compression-vs-embeddings race, warm-atlas identity, and reproduction commands |

## The code (lives with the system, not here)

| where                      | what                                                                           |
| -------------------------- | ------------------------------------------------------------------------------ |
| `src/surface/face/relate/` | product face (nine query verbs + lifecycle + schema)                           |
| `src/kernel/kinship/`      | sketch (LZJD) · silhouette (structure) · lexicon (recall) · zipper (exact ΔAb) |
| `src/kernel/batch/`        | `patterns` / loom (N-pattern exact attribution)                                |
| `src/corpus/index/atlas/`  | persisted kinship atlas (warm `similar`/`dups`/`clusters`/`echoes`)            |
| `src/corpus/index/codex/`  | FM-index shelf behind `quote` (shared with `gist codex`)                       |
| `bench/relate/`            | compression-vs-embeddings knn harness (`zig build relate-knn`)                 |

## Run

```bash
make install-gist                      # installs relate beside gist
relate similar path/to/file --top 5
relate pack "how does CDC recover?" --top 8
relate quote 'a pasted snippet'
relate index --shelf                   # kinship atlas + codex shelf
relate status --json
cd libs/kernels/irregex && zig build test
zig build relate-knn                   # see TESTING.md
```

## Status

**Shipped.** Dogfooded for similarity, duplication, context packing, and
provenance (`irregex.mdc`). Start with the positive case in
[`CLAIM.md`](CLAIM.md), audit its ancestry in
[`PRIOR_ART.md`](PRIOR_ART.md), then test every assertion against
[`TESTING.md`](TESTING.md). The operational product face lives in
[`src/surface/face/relate/README.md`](../../src/surface/face/relate/README.md).
