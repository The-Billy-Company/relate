---
doc_radar:
  sentinels:
    - description: "relate exposes kinship / retrieval / sweep, not gist search"
      file: bindings/rust/src/lib.rs
      contains: ["pub fn similar", "pub fn pack", "pub fn patterns"]
      absent: ["pub mod exact", "pub mod compose"]
    - description: "relate depends on the irregex substrate"
      file: bindings/rust/Cargo.toml
      contains: ["irregex ="]
---

# relate — kinship, retrieval, and sweep

The Rust face of the `relate` package. Twelve verbs over compression kinship,
priced retrieval, and multi-pattern sweeps. Every verb returns the shared
[`irregex::runtime::Rows`] cursor.

```rust
use relate::{similar, Grade};

let kin = similar("src/lib.rs").min_grade(Grade::Strong).rows()?;
for row in kin.iter() {
    let row = row?;
    println!("{:?}  {:?}", row.text("path"), row.real("distance"));
}
```

Depends on [`irregex`](../../../irregex/bindings/rust/) for the substrate
(path in-tree; crates.io version once published). Does not re-export gist's
search surface or blast's composed verbs.
