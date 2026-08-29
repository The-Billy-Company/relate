- **`cargo publish` reaches crates.io again.** Both 1.1 releases tagged, built,
  and shipped the wheel and the Go module, and both left crates.io on 1.0.0 —
  each dying at a different step of the same knot. v1.1.0 could not load the
  sibling `irgx` manifest at all; v1.1.1 got past that and died on the uncommitted `Cargo.lock` that the re-pin
  had just written.

  A lockfile records a version for every package it resolved, and two of those
  are ours: `relate-search`, whose manifest the release bot bumps and whose lock entry
  it does not, and `irgx`, which moves on irregex's release schedule rather than
  on this one. `cargo publish --locked` is the one command that refuses a stale
  lock instead of quietly reconciling it — and the rewrite that makes the lock
  true then leaves the checkout uncommitted, which cargo refuses separately.

  So both halves are answered. `tools/relock.py` finds the
  local packages by walking the manifest graph instead of being told their
  names, reads each declared version off disk, and rewrites that one
  `version = "..."` line — a third local package added later is covered the day
  it exists. Nothing is re-resolved and no registry is contacted, so no
  third-party pin can move. And the publish now pairs `--locked` with
  `--allow-dirty`, which read like a contradiction and are not: the graph must
  already be the one that was tested, and the single file that makes that true
  is allowed to be the one this step just wrote.
