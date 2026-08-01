`relate` ships its own CLI now.

The face and the CLI vocabulary (`flags` · `grade` · `manifest` ·
`reprise`) moved here from the `gist` package, where they had lived only
because an earlier cycle forced the binary into the product chassis. The
FM-index shelf's move into `irregex` broke that cycle; this finishes the
split. `zig build` produces a `relate` binary. The face dials gist's
resident daemon for the answer keep (`@import("gist")`), so a recalled
sweep still turns a 27-second question into milliseconds — the dependency
points the right way now.
