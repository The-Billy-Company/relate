# bench/codex — the self-index at-scale proof

Harness + driver proving `src/corpus/index/codex/` (the compressed self-index) on real
repo bytes at scale. This is the graduation of the
`.local/spikes/shannon-self-index/` rung-1 prototype into the production
module, measured honestly.

| piece       | what                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scale.zig` | `zig build codex-scale -- <corpus> [--sizes-mb …] [--queries N] [--sample-rate R]` — builds the REAL codex over each slice, emits JSON lines (kind=build\|persist\|query\|cento): index bits/char vs measured H₀/H₂, count/find ns/query per pattern length, build/restore wall time, save/load size + latency (the reloaded index re-verified against the oracle), and the Ziv–Merhav cross-parse priced over native vs foreign 256-byte queries. Every timed count is first verified against a naive `std.mem` scan; `restore()` must reproduce the slice byte-exactly or the run dies. |
| `race.sh`   | one-command proof: snapshots a deterministic sorted-path corpus of repo text (~187MB) into `.local/codex-bench/`, runs the ladder, then sizes identical slices with gzip -9 / bzip2 -9 / zstd -19 / xz -9 for the space table.                                                                                                                                                                                                                                                                                                                                                            |

The claims under test (see `src/corpus/index/codex/README.md` for the theorem chain):

1. **space** — the count-index lands under bzip2's neighborhood (both are
   BWT + entropy coding; ours additionally _answers queries_),
2. **time** — count(P) is flat in corpus size, linear in |P| (the Ω(m) floor),
3. **decodability** — the whole corpus restores from the index alone: the
   index IS a lossless compression, not a companion to one,
4. **persistence** — save→load round-trips at a small fraction of build cost
   and the loaded index answers identically (checked, not assumed),
5. **relatedness** — the cross-parse separates native from foreign text by
   ~90× in bits/byte, at O(|query|) parse cost flat in corpus size.

Results land in `.local/codex-bench/{scale.jsonl,compressors.jsonl}`.
