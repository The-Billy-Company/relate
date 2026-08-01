# relate — Python binding

Importable face of the relate compression-as-search product. See
[`relate/README.md`](relate/README.md) for the package layout.

```bash
uv sync --group dev
uv run pytest
```

Depends on the sibling `irregex` binding (path source for local checkouts;
PyPI `irregex` for a published wheel). Behavioral tests also pull `gist` as a
dev oracle for independent exact-search checks.
