# `include/` — public C ABI (`librelate`)

The flat, versioned header non-Zig hosts compile against. One file:
[`relate.h`](relate.h). It `#include`s `<gist.h>` for the warm engine and
`<irgx.h>` for the substrate. Implementation lives in
[`../src/surface/ffi/`](../src/surface/ffi/). Link `librelate`, `libgist`,
and `libirgx`.
