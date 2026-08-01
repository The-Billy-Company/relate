---
doc_radar:
  sentinels:
    - description: "public C ABI keeps relate_run and the relate op macros"
      file: include/relate.h
      contains: ["relate_run", "RELATE_OP_SIMILAR", "RELATE_OP_PATTERNS", "#include <irregex.h>"]
    - description: "Zig artifact root exports the same producer"
      file: src/surface/ffi/exports.zig
      contains: ["export fn relate_run"]
---

# `include/` — public C ABI (`librelate`)

The flat, versioned header non-Zig hosts compile against. One file:
[`relate.h`](relate.h). It `#include`s `<gist.h>` for the warm engine and
`<irregex.h>` for the substrate. Implementation lives in
[`../src/surface/ffi/`](../src/surface/ffi/). Link `librelate`, `libgist`,
and `libirregex`.
