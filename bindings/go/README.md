# `bindings/go/`

Go binding for [relate](../../README.md) — what is like this / what repeats.
Kinship, retrieval, and sweep verbs only. Exact search is gist; composed verbs
are blast; the shared contract and runtime are irregex.

```bash
go get github.com/The-Billy-Company/relate/bindings/go
```

Default build is pure Go (answers through the `relate` binary). In-process is
opt-in: `go build -tags irgx_ffi` after `zig build` has minted
`zig-out/lib/librelate.dylib`.

```go
import (
    "github.com/The-Billy-Company/irregex/bindings/go/analytic"
    "github.com/The-Billy-Company/relate/bindings/go"
)

c := relate.Over("src").In(repoRoot)
near, _ := c.Similar(ctx, analytic.Kinship{Target: "runtime/row.go", Top: 5})
```

Release tags are nested: `bindings/go/vX.Y.Z`.
