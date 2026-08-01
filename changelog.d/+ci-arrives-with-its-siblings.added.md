`relate` has CI. Four jobs on push and pull request: the Zig engine (`check`
then `test`, on Linux and macOS, because the build branches on the host for the
`libtool` re-archive and for `@loader_path` against `$ORIGIN`), plus one job
each for the Python, Go, and Rust bindings.

The interesting part is that a clone of this repository cannot build. Every
face resolves its dependencies as sibling paths; `../irregex` and `../gist` in
build.zig.zon, `../../../irregex/bindings/go` in the Go module's replace, the
same shape again in Cargo.toml and pyproject.toml. All of those are relative to
the directory holding this one, which a bare checkout does not have. Rather
than teach CI a second spelling of the dependency graph, the workflow checks
this repo out one level down and drops `irregex` and `gist` beside it, so a
runner's layout is a developer's layout and every relative path means the same
thing in both places. `actions/checkout` refuses to write above the workspace,
which is what forced descending rather than ascending.

The binding jobs each build the Zig CLI, which the substrate's own CI has no
reason to do. relate vendors no archive of its own, so its bindings answer by
shelling the `relate` binary and skip when there isn't one. Rust is why that
became worth guarding: its skip is an early `return`, which the harness reports
as `ok`, so a job that built nothing would have gone green having asserted
nothing at all. Each build step now proves the binary exists before the suite
that needs it runs.

The measurement lanes stay out. `lab`, `relate-knn`, and `codex-scale` are
timing tools, and a duration measured on a shared runner is noise wearing a
decimal point.
