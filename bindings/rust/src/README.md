# `src/` — relate verb modules

| File | Job |
|---|---|
| `lib.rs` | twelve free functions + re-exports from `irregex` |
| `kinship.rs` | `similar` · `echoes` (legacy `dups`/`clusters`/`concepts` wrappers spell today's CLI) · … |
| `retrieval.rs` | `recall` · `pack` · `quote` |
| `sweep.rs` | `patterns` · `pattern_counts` |

Calibration bands come from `relate/contract/kinship.toml`; row schemas and
verb ops come from `irregex/contract/analytic.toml` via the generated table in
the `irregex` crate.
