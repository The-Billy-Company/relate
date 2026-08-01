---
doc_radar:
  sentinels:
    - description: "C ABI producer exports live in the artifact root"
      file: src/surface/ffi/exports.zig
      contains: ["export fn relate_run"]
    - description: "public header declares relate_run and includes the substrate"
      file: include/relate.h
      contains: ["int32_t relate_run(", "#include <gist.h>", "#include <irregex.h>"]
---

# surface/ffi — in-process C-ABI kinship producer

`relate_run` materializes a kinship, retrieval, or multi-pattern-sweep answer
into an `irregex_rows *` walked by `libirregex`. The warm engine handle comes
from `libgist` (`gist_engine_open`); this library does not redefine the
substrate or the session.

## Shape

| Symbol | Role |
| --- | --- |
| `relate_run(engine, op, params, cancel, out)` | materialize one verb into an `irregex_rows *` |
| `irregex_rows_next` / `_next_batch` / `_stats` / `_close` | walk that cursor (`libirregex`) |

A verb this build cannot answer in-process returns `IRREGEX_STALE`. Bindings
shell the CLI for that verb unchanged. An op this library does not own
(`rank`, compose) is `IRREGEX_INVALID`.

### Files

| File | Owns |
| --- | --- |
| `exports.zig` | The `librelate` artifact root — `export fn relate_run` |
| `analytic.zig` | Dispatch + the in-process `patterns` / `pattern_counts` sweep |

C declarations: [`../../../include/relate.h`](../../../include/relate.h).
