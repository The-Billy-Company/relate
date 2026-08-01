# `src/surface/face/` — the `relate` binary face

The dispatch shell for the `relate` command. This directory is the face
only: argv, verb dispatch, and rendering. The engine it drives — the
kinship metric, the codex, the anatomy silhouettes, the warm tier, and
the persisted atlases — lives under `src/kernel/`, `src/corpus/`, and
`src/exec/` in this same package.

The flag surface and the grade vocabulary this face renders live one level
out, in [`../cli/`](../cli/). The answer keep dials gist's resident daemon
through `@import("gist")`.

| File            | Owns                                                                 |
| --------------- | -------------------------------------------------------------------- |
| `main.zig`      | Binary identity: which repertoire it wears, the brand name           |
| `repertoire.zig`| The one verb table — help, `--schema`, dispatch, unknown-verb line   |
| `similar.zig`   | The neighbor verb                                                    |
| `echoes.zig`    | The repetition verb                                                  |
| `pack.zig`      | Anti-redundant coverage                                              |
| `quote.zig`     | Codex quotation                                                      |
| `patterns.zig`  | Multi-pattern exact sweep                                            |
| `lifecycle.zig` | `index` / `status`                                                   |
| `options.zig`   | Shared query option surface                                          |
| `units.zig`     | Unit view (file / function / match)                                  |
| `kinship.zig`   | Shared plumbing: view resolver + verified-pair machinery             |

## When to edit

A user-visible verb, flag, help string, or `--schema` field. Kinship math
stays in `src/kernel/kinship/`; daemon transport stays in the `gist`
package.
