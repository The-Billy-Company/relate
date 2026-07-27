# `src/kernel/kinship/metric/` — how far apart two bodies are

Two symmetric relatedness channels over the same estimator (`distance = 1 −
Jaccard` on phrase sketches), differing only in what they sketch — plus the
shared channel vocabulary and the parallel fingerprinting pass that builds
records from raw bytes.

## Files

| File              | Job                                                                                                                                                                                                         |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sketch.zig`      | The byte channel — LZJD over LZ78 phrase-dictionary bottom-k MinHash (`min_phrase=3` noise floor); backs `relate similar` / `echoes --as copies`                                                           |
| `silhouette.zig`  | The structure channel — MOSS-style winnowed shingles over a normalized token stream (identifiers→I, numbers→N, strings→S, comments dropped, pan-language keywords kept), KMV bottom-k; backs `--as shapes`  |
| `channel.zig`     | The channel vocabulary (`copies` · `twins` · `shapes` · `any` · `recall` · `context`) and its calibrated grade bands — one set of cut points the kernel and every renderer share                            |
| `fingerprint.zig` | Parallel bytes→record pass: byte-balanced sharding over `primitives/parallel.zig`, fail-to-`empty` degradation; the live rung and the atlas freshness fold both build through here                          |

An identical skeleton under renamed identifiers reads **exactly 0** on the
structure channel while the byte channel reads far — the gap is what `echoes`
ranks on. Proven in `sketch_test.zig` / `silhouette_test.zig`.

## When to edit

Metric parameters, normalization classes, winnowing, channel cut points, or
the parallel fingerprinting discipline. The pair/cluster machinery that
consumes these distances lives in [`../cluster/`](../cluster/).
