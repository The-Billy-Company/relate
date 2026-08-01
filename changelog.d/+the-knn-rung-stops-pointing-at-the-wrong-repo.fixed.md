The compression-vs-embeddings rung told you to go looking for it in the wrong
place, three different ways. Two docs cited the harness as `bench/knn/knn.zig`,
a path that has not existed since the rung moved under
`bench/conformance/relate/`. Worse, `TESTING.md` opened its reproduction block
with `cd ../gist`, on the theory that the harness lived in the product chassis
next door — but `relate-knn` is wired into this package's own `build.zig`, and
`gist` has no such step, so following the instructions landed you in a repo
where the command does not exist.

The paths now name the real file and the block runs from this repo root. While
proving the step was here, the other half of the problem surfaced: `relate-knn`
takes a dataset directory holding a `manifest.tsv`, and the driver that wrote
that manifest went with the prototype race whose write-up already didn't ship.
The harness is real and the lanes it prices are real; what is missing is the
labeled corpus and the few lines that lay it out. Both docs now say so, because
"the harness is, so it stays re-runnable" reads as *clone and run it*, and that
is a promise this package cannot currently keep.
