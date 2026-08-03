# `bindings/go/`

Go binding for [relate](../../README.md) — what is like this / what repeats.
Kinship, retrieval, and sweep verbs only. Exact search is gist; composed verbs
are blast; the shared contract and runtime are irregex.

```bash
go get github.com/The-Billy-Company/relate/bindings/go
```

The module root is the package, so the import path is the one you just fetched.

Default build is pure Go, answering through the `relate` binary, so that has to
be on `PATH` (or `$RELATE_BIN`);
[the repository](https://github.com/The-Billy-Company/relate) builds it with
`zig build`. In-process is opt-in: `go build -tags irgx_ffi` after `zig build`
has minted `zig-out/lib/librelate.dylib`.

```go
import (
    "github.com/The-Billy-Company/irregex/bindings/go/analytic"
    "github.com/The-Billy-Company/relate/bindings/go"
)

c := relate.Over("src").In(repoRoot)
near, _ := c.Similar(ctx, analytic.Kinship{Target: "runtime/row.go", Top: 5})
```

The module is nested, so the proxy resolves it by a subdirectory-prefixed tag —
`bindings/go/v1.0.0`, not `v1.0.0`. `go get` handles that; it only matters if
you are reading the tag list.
