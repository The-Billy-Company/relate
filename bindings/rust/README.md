# relate - code similarity search for Rust

The Rust face of the `relate` package: near-duplicate files, clone families,
and where a snippet came from, by compression rather than embeddings. Twelve
verbs over compression kinship, priced retrieval, and multi-pattern sweeps.
Every verb returns the shared [`irgx::runtime::Rows`] cursor.

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
