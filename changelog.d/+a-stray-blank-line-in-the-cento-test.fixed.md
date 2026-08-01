`src/kernel/codex/cento_test.zig` ended with a blank line after its closing
brace, left behind when the CLI moved into this repository. It had been sitting
in `main` unnoticed, which is the entire argument for the formatter gate landing
alongside it — nobody was ever going to catch a trailing newline by reading.

Whitespace only, and checked rather than assumed: the file's bytes with all
whitespace stripped hash identically before and after, and the three `cento`
tests pass on both sides of the change.
