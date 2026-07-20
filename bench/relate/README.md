---
doc_radar:
  sentinels:
    - description: "the relate-knn harness is a wired build step + exposes all three lanes"
      file: libs/kernels/irregex/build.zig
      contains: '.step("relate-knn"'
    - description: "the three faithful lanes the harness runs"
      file: libs/kernels/irregex/bench/relate/knn.zig
      contains: 'const Method = enum { zipper, sketch, pivot };'
---

# bench/relate — compression-as-embedding proof harness

`knn.zig` (`zig build relate-knn`) runs the **real** relate engine as a
k-NN text classifier over a labeled manifest, so "compression vs embeddings"
is a measured race, not a claim. It re-uses production code only — the
`zipper` cross-parse (`src/search/similarity/zipper.zig`), the `sketch` LZJD
distance (`src/search/similarity/sketch.zig`) — never a re-implementation.

## Lanes (`--method`)

| Lane     | Machinery                                                                                                                                        |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `zipper` | one suffix automaton per train doc; each test doc priced by exact Ziv–Merhav cross-parse (distance = conditional length / cold length)           |
| `sketch` | one LZJD dictionary sketch per doc; bottom-k Jaccard distance                                                                                    |
| `pivot`  | **compression embeddings** — each doc → the P-vector of its cross-parse cost to P pivots (FastMap/Lipschitz), then Euclidean k-NN (`--pivots P`) |

## Input

A manifest the driver writes (deterministic order — never a walk of the
coworker-mutated tree): `<dataset>/manifest.tsv`, rows `<split>\t<label_id>\t<relpath>`,
`split ∈ {train,test}`. Every doc is pre-truncated to a uniform byte cap so all
lanes (this one, gzip, embeddings) price identical bytes. Result is one JSON
object on stdout; the timing line on stderr.

```bash
zig build -Doptimize=ReleaseFast                         # builds zig-out/bin/relate-knn
zig-out/bin/relate-knn <dataset> --method zipper --k 3   # from the repo root
```

## Finding

The full head-to-head (vs gzip-kNN ACL 2023 + a static-embedding model) and the
**KILL verdict** — embeddings win on both accuracy and amortized query speed for
semantic retrieval; compression's only edge is model-free cold-start — live in
the spike dossier `.local/spikes/compression-vs-embeddings/SPIKE.md`.
