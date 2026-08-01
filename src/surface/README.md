# `src/surface/` — the product surface

What a caller types and what they see. Two leaves:

| Leaf | Role |
| ---- | ---- |
| [`cli/`](cli/) | Shared face vocabulary — flags, verb-table rendering, grades, answer keep |
| [`face/`](face/) | The `relate` binary — repertoire + verb drivers |

The engine underneath (`kernel/`, `corpus/`, `exec/`) does not import this
directory except through `root.zig`'s re-export shelf. The answer keep dials
the `gist` package's resident daemon; everything else stays in this tree.
