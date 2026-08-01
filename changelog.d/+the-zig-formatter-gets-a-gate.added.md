A fifth CI job, and it checks the one formatter nothing here was checking.
Rust already had `cargo fmt --check` inside its own job; Zig, which is what this
package is actually written in, had nothing.

That gap is not theoretical. `zig fmt` lays a column-aligned multiline literal
out as a padded grid, so a rename that shrinks the widest cell in a column
leaves every row beneath it one space too wide — in files nobody opened. The
sibling substrate shipped exactly that and no gate said a word. This one found
committed drift here on its first run.

Its own job, for the reason the other four are: a formatting nit and an engine
regression should not arrive as the same red X. It is also the only job here
that skips the three-checkout preamble, because reading files is not
configuring a build and none of the sibling path dependencies apply. It pins
the same Zig the engine builds with, since the formatter's output is a property
of the compiler release — a different Zig is a different grid.

The file list is enumerated with `git ls-files -co --exclude-standard '*.zig'`
rather than written out, because a path list goes stale the same silent way the
formatting does, and stale in the direction that checks less. Tracked plus
untracked-not-ignored is 53 files today, and a new top-level directory cannot
escape it. What it leaves out is exactly the ignored trees, `.zig-cache` and
the fetched `zig-pkg/`, so the exclusions live in `.gitignore` where someone
can read them, instead of being whatever fell outside an argument list. The one
piece that looks like belt-and-braces is the existence test on each path, and
it is not: `git ls-files` still names a tracked file you have deleted, so
without it a mid-edit working tree fails the gate with `FileNotFound` and
teaches everyone to ignore it.
