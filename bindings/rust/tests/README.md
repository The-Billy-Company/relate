# relate crate tests

- `analytic.rs` — kinship / retrieval / sweep end-to-end against the certified
  `relate` binary. Expectations come from `[row_schemas]` / `[grades]`, never
  from a previous run. **Fails** when no `relate` binary answers `--schema`,
  rather than skipping: Rust's stable harness reports an early return as `ok`,
  so a skip here is a green tick over an untested seam. Build one with
  `zig build`, or point `RELATE_BIN` at it.
