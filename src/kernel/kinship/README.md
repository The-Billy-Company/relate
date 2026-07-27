---
doc_radar:
  sentinels:
    - description: "the byte channel is LZJD over LZ78 phrase sketches"
      file: libs/kernels/irregex/src/kernel/kinship/metric/sketch.zig
      contains: "LZJD"
    - description: "the structure channel winnows a normalized token stream"
      file: libs/kernels/irregex/src/kernel/kinship/metric/silhouette.zig
      contains: "Winnowing"
    - description: "lexicon nominates; zipper decides via Ziv–Merhav cross-parse"
      file: libs/kernels/irregex/src/kernel/kinship/recall/zipper.zig
      contains: "Ziv"
---

# `src/kernel/kinship/` — compression relatedness

The `relate` engine's math: measure how alike two byte bodies are by how
cheaply one describes the other — no parsers, no language list, no embeddings.
Pure kernel math; verb dispatch and rendering live in
[`../../surface/face/relate/`](../../surface/face/relate/).

The floor splits by the **question** each group answers:

| Group                  | Question                                          | Files                                               |
| ---------------------- | ------------------------------------------------- | --------------------------------------------------- |
| [`metric/`](metric/)   | _How far apart are two bodies?_                   | `sketch` · `silhouette` · `channel` · `fingerprint` |
| [`cluster/`](cluster/) | _Which bodies (or functions) are the same thing?_ | `pairs` · `families` · `echoes`                     |
| [`recall/`](recall/)   | _Which files best explain a query?_               | `lexicon` · `zipper` · `coverage`                   |

## Pipeline

Two questions reach these kernels, and the probe's shape or the sweep's channel
picks the path:

```text
relate similar <text>  →  persisted codebook nominates → bounded zipper decides  (recall)
relate pack            →  persisted codebook prices query chunks → marginal coverage (recall)
relate similar <path>  →  sketch or silhouette distances, per --as               (metric)
relate echoes          →  buckets nominate → the channel's records verify        (metric→cluster)
                          --shape pairs | families (closure) | distinct (complement)
```

Persisted sketches for the warm atlas live in
[`../../corpus/index/atlas/`](../../corpus/index/atlas/); per-function
silhouettes for `--unit function` in
[`../../corpus/index/frag/`](../../corpus/index/frag/). The retrieval path shares
the compact trigram codebook under
[`../../corpus/index/trigrams/`](../../corpus/index/trigrams/) rather than
persisting a second dense fingerprint index.

## Distance intuition

`distance = 1 − Jaccard` over LZ78 phrase sketches:

| Distance | Meaning                             |
| -------- | ----------------------------------- |
| ≤ 0.05   | Near-exact copy                     |
| ≤ 0.25   | Same-thing-drifted (copies default) |
| ≥ 0.5    | Shares style, not substance         |

Structure (silhouette) distance is the same estimator over a different set —
winnowed token shingles after normalization — so an identical skeleton under
renamed identifiers reads **exactly 0** there while the byte channel reads far.
The gap (`echo = bytes − structure`) is `relate echoes`' ranking signal; it
deliberately carries **no absolute dup threshold** (measured: none separates
cleanly across corpora).
