<!--
doc_radar:
  sentinels:
    - file: kinship.go
      contains:
        - "func Over(roots ...string) *Corpus"
        - "func (c *Corpus) Similar(ctx context.Context, k analytic.Kinship) ([]Neighbor, error)"
        - "func (c *Corpus) Dups(ctx context.Context, k analytic.Kinship) ([]Pair, error)"
        - "func (c *Corpus) Clusters(ctx context.Context, k analytic.Kinship) ([]Cluster, error)"
        - "func (c *Corpus) Echoes(ctx context.Context, k analytic.Kinship) ([]Echo, error)"
        - "func (c *Corpus) Concepts(ctx context.Context, k analytic.Kinship) ([]Concept, error)"
        - "func (c *Corpus) Fragments(ctx context.Context, k analytic.Kinship) ([]Family, error)"
        - "func (c *Corpus) Distinct(ctx context.Context, k analytic.Kinship) ([]Lone, error)"
    - file: retrieval.go
      contains:
        - "func (c *Corpus) Recall(ctx context.Context, r analytic.Retrieval) ([]Recalled, error)"
        - "func (c *Corpus) Pack(ctx context.Context, r analytic.Retrieval) ([]Pick, error)"
        - "func (c *Corpus) Quote(ctx context.Context, r analytic.Retrieval) (Quotation, error)"
        - "func (c *Corpus) Patterns(ctx context.Context, s analytic.Sweep) ([]Hit, error)"
        - "func (c *Corpus) Counts(ctx context.Context, s analytic.Sweep) ([]Count, error)"
    - file: ../../contract/kinship.toml
      contains:
        - "[grades]"
-->

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
