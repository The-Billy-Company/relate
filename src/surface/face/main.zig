//! relate — the compression-search CLI (the `relate` binary).
//!
//! What if compression was a text search algorithm? relate is that question as
//! a product: nine query verbs + its own index lifecycle over the relate
//! engine + irregex primitives (relate ∪ match ∪ weave), riding the same
//! corpus policy as the `gist` binary.
//!
//! **Nothing about the surface is written here.** The verbs are declared once
//! in `repertoire.zig` — each row carrying its usage form, both descriptions,
//! and the handler that runs it — and `surface/cli/manifest.zig` renders the
//! help, the `--schema` manifest, the dispatch, the unknown-verb line, and the
//! process itself (argv, the introspection conventions, the exit contract)
//! from that one table. This file is the binary's identity: which repertoire
//! it wears.
//!
//! Verb drivers live beside this file under `src/surface/face/`; the
//! compression engines live under `src/kernel/kinship/` and the persisted
//! tiers under `src/corpus/index/`, reached through the `relate` module.

const std = @import("std");
const irregex = @import("irregex");
const relate = @import("relate");

/// Sign diagnostics as the program the user actually typed. Only the name
/// moves: the knob namespace and artifact directory stay the ecosystem's, since
/// this binary reads the index and atlas `gist` writes.
pub const irgx_brand: irregex.Brand = .{ .name = "relate" };

pub fn main(init: std.process.Init) void {
    // Thin exe root: driver code is analyzed inside the relate module (so
    // relative imports resolve and no file belongs to two modules) and
    // reached as `@import("relate").faces.*` / `.cli.*`.
    relate.cli.manifest.drive(
        relate.faces.repertoire.face,
        irregex.version_string,
        init,
    );
}
