# `src/kernel/kinship/cluster/` — which bodies are the same thing

Turns pairwise [`../metric/`](../metric/) distances into groups: candidate
buckets nominate, exact verify decides, union-find closes the graph into
families. `concepts` lifts the same idea to function granularity.

## Files

| File           | Job                                                                                                                                                    |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `pairs.zig`    | Pair machinery — bottom-16 seed-hash candidate buckets nominate, exact pairwise verify decides; the shared kernel under `dups` / `clusters` / `echoes` |
| `families.zig` | Union-find (`Forest`) over the verified dup graph — the transitive closure `clusters` reports as fork families                                         |
| `concepts.zig` | Function-level concept discovery — the same nominate→verify seam over per-function fragments rather than whole files                                   |

## When to edit

Bucketing, verification thresholds, or the family-closure policy. The exact
byte/structure estimators these buckets are built from live in
[`../metric/`](../metric/).
