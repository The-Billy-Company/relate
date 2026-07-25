# `src/kernel/kinship/cluster/` — which bodies are the same thing

Turns pairwise [`../metric/`](../metric/) distances into groups: candidate
buckets nominate, exact verify decides, union-find closes the graph into
families. One survey answers at either granularity — a whole file or a single
extracted function — because the unit is a parameter, not a second engine.

## Files

| File           | Job                                                                                                                                                                        |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pairs.zig`    | Pair machinery — bottom-16 seed-hash candidate buckets nominate, exact pairwise verify decides; the shared kernel every channel rides                                      |
| `families.zig` | Union-find (`Forest`) over the verified graph — the transitive closure `--shape families` reports, and the set `--shape distinct` complements                              |
| `echoes.zig`   | The repetition survey: one `survey` over unit × channel × answer shape, with the noise floors (per-channel mass, min-lines, generated-file exclusion) applied in one place |

## When to edit

Bucketing, verification thresholds, the noise-floor calibration, or the
family-closure policy. The exact byte/structure estimators these buckets are
built from live in [`../metric/`](../metric/); the channel vocabulary and its
calibrated grades live in [`../metric/channel.zig`](../metric/channel.zig).
