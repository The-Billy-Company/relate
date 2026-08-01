# `src/kernel/kinship/recall/` — query → the files that best explain it

Content retrieval by compression, not regex: price how cheaply each corpus file
would describe a query, then either rank the winners (`search`) or greedily
assemble the non-redundant set that covers it (`pack`).

## Files

| File           | Job                                                                                                                                |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `lexicon.zig`  | Live fallback oracle — corpus-priced winnowed fingerprints plus exact short-query recovery; nominates candidates                   |
| `zipper.zig`   | Exact decider — suffix-automaton Ziv–Merhav cross-parse charging real code lengths (paper's ΔAb; no compressor subprocess)         |
| `coverage.zig` | Greedy submodular max-coverage (`greedy`) over corpus-priced fingerprints — the `pack` core, pricing each pick by marginal novelty |

## Pipeline

```text
relate similar TEXT → lexicon nominates → bounded zipper decides → rank by coding gain
relate pack   →  lexicon prices query chunks → coverage picks marginal-novel files
```

The persisted codebook these read lives in the irregex library under
`irregex/src/corpus/index/trigrams/`; the cold
read engine that folds it against live bytes is
[`../../../exec/retrieval/retrieval.zig`](../../../exec/retrieval/retrieval.zig).

## When to edit

Pricing model, candidate nomination, or coverage marginals. Verb dispatch stays
in the gist product chassis
(`gist/src/surface/face/relate/`).
