# relate - code similarity search for Rust

The Rust face of the `relate` package: near-duplicate files, clone families,
and where a snippet came from, by compression rather than embeddings. Twelve
verbs over compression kinship, priced retrieval, and multi-pattern sweeps.
Every verb returns the shared [`irgx::runtime::Rows`] cursor.

```bash
cargo add relate-search
```

The package on crates.io is
[`relate-search`](https://crates.io/crates/relate-search) and the library is
`relate`, so you still write `use relate::…`. The bare name belongs to an
unrelated crate and names there are permanent, which is the same reason the PyPI
distribution is `relate-search` too.

```rust
use relate::{similar, Grade};

let kin = similar("src/lib.rs").min_grade(Grade::Strong).rows()?;
for row in kin.iter() {
    let row = row?;
    println!("{:?}  {:?}", row.text("path"), row.real("distance"));
}
```

Every verb answers by running the `relate` binary, so that has to be on `PATH`
(or `$RELATE_BIN`); [the repository](https://github.com/The-Billy-Company/relate)
builds it with `zig build`.

Depends on [`irgx`](https://crates.io/crates/irgx) for the substrate - resolved
from the registry in a published build, by path in this checkout. Does not
re-export gist's search surface or blast's composed verbs.
