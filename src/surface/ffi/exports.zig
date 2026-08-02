//! `librelate` — the C-ABI artifact's root, and nothing else.
//!
//! This file exists to be a *different* root from `src/root.zig`. A Zig
//! `export fn` is emitted by every compilation that reaches it, so if these
//! shims lived in the library module, then `libblast` — which imports that
//! module — would carry its own copy of `relate_run`, and a host linking both
//! would get a duplicate-symbol error for a symbol it asked for once. Keeping
//! the `export fn`s in the artifact's root instead means the symbols exist
//! exactly where the `.a`/`.dylib` named after them is.
//!
//! Header: `include/relate.h`. Body: `analytic.zig`. Substrate walk symbols
//! come from `libirgx`; the warm engine comes from `libgist`.

const irregex = @import("irregex");
const analytic = @import("analytic.zig");

const api = irregex.api;
const answer = irregex.ffi.answer;
const rows = irregex.ffi.rows;

/// Run relate verb `op` with its declared params family and materialize a row
/// cursor into `*out`. Returns 0 on success, or negative — where −1 (stale)
/// means this tier declines and the caller should answer through the CLI
/// fallback, NOT that the query failed.
export fn relate_run(
    eng: *api.Engine,
    op: u32,
    params: ?*const rows.Params,
    cancel: ?*api.CancelToken,
    out: ?**answer.Answer,
) i32 {
    return @intFromEnum(analytic.run(eng, op, params, cancel, out));
}
