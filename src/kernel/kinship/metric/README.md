# `src/kernel/kinship/metric/` — how far apart two bodies are

Two symmetric relatedness channels over the same estimator (`distance = 1 −
Jaccard` on phrase sketches), differing only in what they sketch.

## Files

| File | Job |
| ---- | --- |
| `sketch.zig` | The byte channel — LZJD over LZ78 phrase-dictionary bottom-k MinHash (`min_phrase=3` noise floor); backs `relate similar` / `dups` |
| `silhouette.zig` | The structure channel — MOSS-style winnowed shingles over a normalized token stream (identifiers→I, numbers→N, strings→S, comments dropped, pan-language keywords kept), KMV bottom-k; backs `relate similar --lens structure` / `echoes` |

An identical skeleton under renamed identifiers reads **exactly 0** on the
structure channel while the byte channel reads far — the gap is what `echoes`
ranks on. Proven in `sketch_test.zig` / `silhouette_test.zig`.

## When to edit

Metric parameters, normalization classes, or winnowing. The pair/cluster
machinery that consumes these distances lives in [`../cluster/`](../cluster/).
