# `src/surface/cli/` — the face vocabulary

The plumbing the `relate` face (and `blast`'s composed face) speaks to the
terminal: argv value parsing, the verb table a face is described by, kinship
grade verdicts, and the answer-keep passenger that dials gist's resident
daemon. It lives here, a sibling of [`face/`](../face/), so both faces share
one spelling of a flag value, one root boundary rule, and one hint grammar
instead of forking them per binary.

| File           | Owns                                                                                                                                                                                                                                                                                          |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `flags.zig`    | Argv → values + roots: `need` (value after a flag), `count`/`minSize`/`unitFloat` (bounded number parses), `onlyFlag` (lifecycle parse), `Roots`/`rootsOf` (positional → corpus roots), `stripDotSlash` + `underAnyRoot` (path/root membership)                                              |
| `manifest.zig` | The verb table a face declares itself as (`Face`/`Verb`/`Flag`/`Retired` with typed defaults), and the renderings derived from it: `--help`, the `--schema` JSON manifest with its shared envelope, verb dispatch, and the unknown-verb line                                              |
| `grade.zig`    | The surface half of kinship judgment (the `Channel`/`Grade` vocabulary itself is a kernel fact, re-exported here): `Sift`, the shared emit ledger every ranking verb runs — cap, drop vanished rows, remember the strongest score, withhold under `--min-grade` — and the `Verdict` it reports when an answer is weak |
| `reprise.zig`  | Asking the same question twice: for a verb whose answer is a pure function of the corpus, consult gist's resident daemon's answer keep before running it and offer the rendered result back after. Owns the key (argv + cwd + scoping env + the running binary's own identity) and the stdout carbon copy |

## Why it sits beside `face/`, not inside it

A face is a product binary; this is the vocabulary a face is built from.
`blast` consumes the same flag and manifest modules through
`@import("relate").cli`, so hosting them under the face would force that
sibling to reach across. Depending downward is fine: `cli/` imports the cold
engine's `die`/`oom` and JSON escaper (`@import("irregex")`) and the corpus
walk/scope; `reprise` dials the daemon through `@import("gist")`. Nothing
here imports a face.

## When to edit

Flag-value parse shapes, the corpus-root resolution/membership rule, how a
face renders itself, or what a kinship score is worth. What each face's verbs
_are_ stays in that face's `repertoire.zig`
([relate](../face/repertoire.zig) ·
`blast/src/surface/face/blast/repertoire.zig`) — this directory renders a
verb table, it never enumerates one. Kinship math stays in
`src/kernel/kinship/`.
