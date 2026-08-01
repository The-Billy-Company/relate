`relate-knn` and `codex-scale` are wired into `build.zig`. Both sources came
across in the split with no build graph to reach them, so the k-NN retrieval
proof and the codex self-index scaling proof were unbuildable code.

Both had also gone stale against the new package boundary, in opposite
directions. `knn.zig` still reached for `irregex.relate.zipper` and
`irregex.api.relate.sketch` — one engine used to hold everything, and the `api`
facade re-exported the second — where the kinship kernels are this package's
`relate.kinship` today and the facade no longer exists. `scale.zig` reached
`cento.zig` by a relative path that climbed out of its own module root, which
Zig rejects; the FM-index it times moved to the engine package while the
Ziv-Merhav cross-parse that prices a quotation against it stayed here, so the
lane straddles both roots and now names `cento` through `relate.codex`.

`zig build lab` installs both; each is also its own named step. Both compile at
the CLI's ReleaseFast posture, since both are timing tools.
