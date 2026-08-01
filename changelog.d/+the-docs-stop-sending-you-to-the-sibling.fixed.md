The split moved the product face and the measurement lanes into this package,
and a handful of docs kept describing the arrangement from before it. The
research map was the worst of them: its code table put the face at
`../gist/src/surface/face/relate/`, a directory that no longer exists, and its
Run block opened by telling you the CLIs ship from the gist sibling. They do
not - `zig build` here installs `relate`, and has since the CLI came home. Two
of its freshness assertions pointed at the same dead path, so they could only
have gone on passing by never being checked.

The reproduction blocks were wrong in a quieter way. Both the knn README and
`TESTING.md` opened with a plain `zig build` and claimed it minted
`zig-out/bin/relate-knn`; it does not, because the lab lanes deliberately sit
off the default install step, so a bare build installs the product binary and
nothing else. `zig build relate-knn` does not fill the gap either - that step
*runs* the harness, so with no dataset it exits 1. Both now say `zig build lab`
and say why.

The evidence table in the root README cited three gates by bare filename -
`patterns_test.zig`, `trawl_test.zig`, `bench/gates/patterns_corpus_parity.sh` -
and none of the three resolves inside this repo: the N-pattern slate is the
library's and the corpus-parity gate is the product chassis's. They are named
with their owning package now, and the row that called the knn race a
"rerunnable comparative harness" says what the other two docs already say -
the harness ships, the labeled corpus does not.

Also swept: the codex README asserted `build.zig` compiles libsais, which this
package has never done (it rides in with the library), `race.sh` gave its own
path as `bench/codex/race.sh` two directories short, and the Rust tests README
still advertised the skip-when-missing behavior that was removed for reporting
`ok` over nothing. No command, path, or number was invented - each one was run
or resolved on disk first.
