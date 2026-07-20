---
doc_radar:
  paths_exist:
    - libs/kernels/irregex/src/cli/relate/main.zig
    - libs/kernels/irregex/src/search/similarity/zipper.zig
    - libs/kernels/irregex/src/search/similarity/lexicon.zig
    - libs/kernels/irregex/bench/relate/knn.zig
  sentinels:
    - file: libs/kernels/irregex/src/search/similarity/sketch.zig
      contains:
        - "Language Trees and Zipping"
        - "LZJD"
    - file: libs/kernels/irregex/src/cli/relate/main.zig
      contains: "search | pack | quote | similar | dups | clusters | echoes | patterns | index | status"
    - file: libs/kernels/irregex/contract/search_api.toml
      contains: "[irregex.verbs]"
---

# Relate — compression-as-search

A **systems/workload composition** that turns compressor-defined relative
entropy into agent primitives over a live working tree: which files describe
this text cheaply, which set covers it without redundancy, what is like this
file, what forked from what, what repeats a skeleton under new names, and
which of N patterns hit where — model-free, deterministic, exact-byte.

The spark is Benedetto, Caglioti & Loreto's *Language Trees and Zipping*
(Phys. Rev. Lett. 2002): two texts are close when one compresses well against
the other's dictionary. Relate graduates that compressor-defined relative
entropy into exact cross-parses, sketches, and a priced fingerprint lexicon
for coding agents.

That composition is the claim. The underlying techniques are established
prior art (survey in `PRIOR_ART.md`). The one place this kernel carries
genuinely new math is on the gist side: the crest sieve
([`../crest/`](../crest/PROOF.md)).

## This folder (research: writing + scope only)

| file | role |
|---|---|
| `CLAIM.md` | precise novelty statement, verb map, explicit non-claims, warm-tier covenant |
| `PRIOR_ART.md` | every citation we actually used (Language Trees → LZJD → winnowing → Ziv–Merhav → FM-index → submodular pack), plus neighboring families we deliberately left |
| `TESTING.md` | exactness gates, kinship evals, knn-vs-embeddings race, warm atlas byte-identity, reproduction commands |

## The code (lives with the system, not here)

| where | what |
|---|---|
| `src/cli/relate/` | product face (ten verbs + lifecycle + schema) |
| `src/search/similarity/` | sketch (LZJD) · silhouette (structure) · lexicon (recall) · zipper (exact ΔAb) |
| `src/search/batch/` | `patterns` / loom (N-pattern exact attribution) |
| `src/index/atlas/` | persisted kinship atlas (warm `similar`/`dups`/`clusters`/`echoes`) |
| `src/index/codex/` | FM-index shelf behind `quote` (shared with `gist codex`) |
| `bench/relate/` | compression-vs-embeddings knn harness (`zig build relate-knn`) |

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

**Shipped.** Dogfooded for similarity / dups / context packing / provenance
(`irregex.mdc`). Prior-art lineage and non-claims: `PRIOR_ART.md`. Composition
claim: `CLAIM.md`. Evidence: `TESTING.md`. Product face:
[`src/cli/relate/README.md`](../../src/cli/relate/README.md).
