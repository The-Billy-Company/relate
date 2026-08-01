---
doc_radar:
  sentinels:
    - description: "the kinship, retrieval, and sweep families are all present"
      file: bindings/rust/src/lib.rs
      contains: ["pub fn similar", "pub fn dups", "pub fn clusters", "pub fn echoes",
                 "pub fn pack", "pub fn quote", "pub fn patterns"]
    - description: "kinship answers are graded, not just scored"
      file: bindings/rust/src/kinship.rs
      contains: ["min_grade", "Grade"]
    - description: "grade bands live in the kinship contract"
      file: ../../contract/kinship.toml
      contains: ["[grades]"]
---

# `src/` — relate verb modules

| File | Job |
|---|---|
| `lib.rs` | twelve free functions + re-exports from `irregex` |
| `kinship.rs` | `similar` · `dups` · `clusters` · `echoes` · … |
| `retrieval.rs` | `recall` · `pack` · `quote` |
| `sweep.rs` | `patterns` · `pattern_counts` |

Calibration bands come from `relate/contract/kinship.toml`; row schemas and
verb ops come from `irregex/contract/analytic.toml` via the generated table in
the `irregex` crate.
