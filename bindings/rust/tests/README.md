# relate crate tests

- `analytic.rs` — kinship / retrieval / sweep end-to-end against the certified
  `relate` binary. Expectations come from `[row_schemas]` / `[grades]`, never
  from a previous run. Skips cleanly when `relate` is not installed.
