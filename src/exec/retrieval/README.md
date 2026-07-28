---
doc_radar:
  sentinels:
    - description: "retrieval is the fingerprint-lexicon path shared by similar/pack"
      file: libs/kernels/irregex/src/exec/retrieval/retrieval.zig
      contains: ["pub fn retrieve", "pub fn pack", "pub const Hit"]
---

# `src/exec/retrieval/` — fingerprint-lexicon retrieval

The kinship retrieval path `relate similar` and `relate pack` ride — shared by
cold and warm so the two transports cannot drift on how a text probe nominates
candidates. Sits beside `cold/` and `session/` as a peer exec package: not a
product face, not pure kernel (it loads persisted atlas / lexicon state).

Kernel math stays in `kernel/kinship/recall/`; this package is the runtime that
binds that math to the corpus artifacts.
