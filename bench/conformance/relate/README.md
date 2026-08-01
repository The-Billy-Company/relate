---
doc_radar:
  sentinels:
    - description: "the knn harness lives in this package (product chassis wires the zig build step)"
      file: bench/conformance/relate/knn.zig
      contains: 'relate-knn'
    - description: "the three faithful lanes the harness runs"
      file: bench/conformance/relate/knn.zig
      contains: 'const Method = enum { zipper, sketch, pivot };'
---

# bench/relate — compression-as-embedding proof harness

`knn.zig` (`zig build relate-knn`) runs the **real** relate engine as a
k-NN text classifier over a labeled manifest, so "compression vs embeddings"
is a measured race, not a claim. It re-uses production code only — the
`zipper` cross-parse (`src/kernel/kinship/recall/zipper.zig`), the `sketch` LZJD
distance (`src/kernel/kinship/metric/sketch.zig`) — never a re-implementation.

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
zig build lab -Doptimize=ReleaseFast                     # builds zig-out/bin/relate-knn
zig-out/bin/relate-knn <dataset> --method zipper --k 3   # from the repo root
```

`lab`, not a bare `zig build`: the measurement lanes sit off the default
install step, so a plain build installs only the `relate` binary. The
`zig build relate-knn` step *runs* the harness, so it wants the dataset —
`zig build relate-knn -- <dataset> --method zipper` is the one-shot form.

## Finding

The **KILL verdict** for semantic retrieval: embeddings win on both accuracy
and amortized query speed; compression's only edge is model-free cold-start.
That came out of an early head-to-head (vs gzip-kNN ACL 2023 + a
static-embedding model) whose write-up never shipped here, so the numbers
behind the verdict are not in this repo. The harness that produced them is;
point it at a labeled manifest and the race runs again.
