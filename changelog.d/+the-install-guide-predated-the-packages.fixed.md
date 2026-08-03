The Install section only knew how to build the CLI from source, which was the
whole story right up until the three bindings shipped. It now names each one
where it is actually served: `relate-search` on PyPI and crates.io, the module
path on the Go proxy, and the identifier you type in each - still `relate`,
because the `-search` suffix is a registry fact rather than an API one.

The Rust README carried the stalest line, promising a "crates.io version once
published" for a substrate that has been [`irgx`](https://crates.io/crates/irgx)
1.0.0 for a while now, and had no install snippet of its own at all.

All three also say what none of them said before: the binding drives the
`relate` binary rather than reimplementing it, so the CLI is a prerequisite, and
a missing one raises `GistNotFoundError` rather than returning nothing.
