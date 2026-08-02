Eighteen READMEs carried a `doc_radar:` block - YAML frontmatter on most, an
HTML comment on the rest - declaring path, count, and sentinel assertions for a
freshness gate that lives in the monorepo this package was split out of. That
gate was never ported here, so every one of those blocks was inert. On
`bindings/python/relate/README.md` it was also the first thing a PyPI reader
would meet, where the renderer turns a YAML preamble into a horizontal rule
followed by a heading made of raw YAML. They are gone, and the prose below each
is untouched.
