---
doc_radar:
  counts:
    - description: "the fragment index — engine + round-trip/corruption/fold suite"
      glob: libs/kernels/irregex/src/corpus/index/frag/*.zig
      unit: files
      equals: 2
  sentinels:
    - description: "the persisted artifact rides the shared GIST_DIR-relocatable artifact home"
      file: libs/kernels/irregex/src/corpus/index/frag/frag.zig
      contains: 'const frag_path = corpus_mod.ArtifactPath("concepts.frag");'
    - description: "freshness folds through the same conservative T3 stat walk"
      file: libs/kernels/irregex/src/corpus/index/frag/frag.zig
      contains: "try fresh.changedSince(gpa, io, roots, f.built_ns, a, &changed);"
    - description: "the lifecycle verb that builds it is relate's own"
      file: libs/kernels/irregex/src/surface/face/relate/lifecycle.zig
      contains: "try persist.writeAtomic(io, frag_mod.fragFile(), fblob);"
---

# frag — the persisted fragment atlas

The atlas makes file-level `relate` warm; **frag** makes function-level
`relate concepts` warm. It persists one entry per authored function
(`kernel/compose/regions.zig` extraction, brace + Python families): the
owning path index, the byte/line span, and a structure silhouette
(`kernel/kinship/metric/silhouette.zig` — winnowed normalized-token shingles). So
concept discovery answers from tens of MiB of `concepts.frag` instead of
re-walking and re-parsing the corpus into functions per invocation. Built by
`relate index`, reported by `relate status`.

Only **silhouettes** are persisted — the structural channel every discovery
nominates on. Byte sketches (for the `bytes` / `echo` lenses) are the
expensive channel, so the driver computes them lazily from live bytes for
just the fragments a query actually nominates, never for the whole corpus.

Same covenant as every irregex index — **an accelerator, never an
authority**:

- the anchor is captured **before** the build's corpus read (the T3
  convention), and `fold` re-derives freshness through the same conservative
  stat walk the atlas/trigram overlays use (`fresh.changedSince`),
  re-extracting every changed/new file's fragments from live bytes — so a
  folded view is byte-equivalent to a live rebuild for every file that still
  exists;
- deletions are invisible to a changed-walk, so the consumer gates **emitted**
  fragments through the shared `frame.onDisk` — O(results) stats, never
  O(corpus);
- `--no-index`, a missing artifact, or a corrupt one all fall back to the full
  live build with identical answers; the parse fails closed on any framing,
  bounds, or checksum violation.
