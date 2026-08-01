---
doc_radar:
  sentinels:
    - file: ../../../contract/kinship.toml
      contains: ["[grades]", "[lifecycle]"]
      description: Grade bands and atlas lifecycle remain kinship-contract sections authored here.
---

# `relate` — kinship and retrieval

The questions a regex cannot ask. Everything here is priced in bits: how
cheaply would this file describe that one, or this corpus describe your text.

Depends on `irregex` for the shared substrate (grades, shell transport, row
decode). Does not import or re-export `gist` or `blast`.

| Module | Concern |
|---|---|
| `corpus.py` | shared scope/argv vocabulary and the graded result container |
| `kinship.py` | `similar` · `pairs` / `families` / `distinct` |
| `retrieval.py` | `recall` · `pack` · `quote` |
| `sweep.py` | `patterns` / `pattern_counts` |
| `lifecycle.py` | atlas / fragment / shelf status and build |

```bash
cd bindings/python && uv sync --group dev && uv run pytest
```
