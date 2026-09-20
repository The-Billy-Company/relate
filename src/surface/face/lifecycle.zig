//! relate — the `index` and `status` lifecycle verbs. relate owns its warm
//! state the way `gist` owns the trigram index: a full engine, not a shim.
//!
//!   relate index [--shelf]     build + persist the kinship atlas
//!                              (`kinship.atlas`: one LZJD sketch + one
//!                              structure silhouette per corpus file —
//!                              index/atlas/atlas.zig); `--shelf` also
//!                              rebuilds the codex shelf `quote` reads (the
//!                              same artifact `gist codex build` writes — one
//!                              shelf, two product faces)
//!   relate status [--json]     is the atlas ready, how big, how fresh — and
//!                              is the codex shelf `quote` needs present
//!
//! The anchor is captured BEFORE the corpus read (the T3 convention), so a
//! file touched mid-build reports as changed on the next query's fold.
//! Persistence is atomic (temp-then-rename) — ~10 coworking agents can race
//! `relate index` against a mid-query load and never observe torn bytes.

const std = @import("std");
const corpus_mod = @import("irregex").corpus;
const Outcome = @import("irregex").inner.cli.outcome.Outcome;
const fresh = @import("irregex").fresh;
const frame = @import("irregex").inner.corpus.frame;
const atlas_mod = @import("../../corpus/index/atlas/atlas.zig");
const frag_mod = @import("../../corpus/index/frag/frag.zig");
const shelf_mod = @import("irregex").codex.shelf;
const assay = @import("irregex").assay;
const home = @import("irregex").index.home;
const allowance = @import("irregex").index.allowance;
const portal = @import("irregex").portal;
const kinship = @import("kinship.zig");
const flags = @import("../cli/flags.zig");

const Dir = std.Io.Dir;

/// Version of the `status --json` machine contract; bump on breaking change.
pub const schema_version = 1;

/// `relate index [--shelf]` — sketch the index corpus, persist the atlas
/// atomically; `--shelf` also rebuilds the codex shelf from the same read.
pub fn runIndex(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const with_shelf = flags.onlyFlag(argv, "--shelf", "usage: relate index [--shelf]\n");
    // Every artifact this verb writes is corpus-shaped — the atlas is a sketch
    // per file, the fragment atlas one per function, the shelf a compressed
    // copy of the whole corpus (69 + 40 + 87 MB on this repository). So both
    // of the artifact home's laws bind here, and harder than they do on the
    // trigram pair: a tree with no edge is not indexed at all, and a tier that
    // does not fit the tree's disk allowance is not written.
    if (!home.hosted()) return refuseUnbounded();

    const run = assay.Run.open(gpa, io, false);
    const built_ns: i64 = @intCast(assay.anchor(io).ns());
    // A build verb: stand at the checkout root, so the atlas keys its sketches
    // by the tree-relative paths `similar`/`echoes` will probe it with.
    const roots = try corpus_mod.enterTree(gpa, io, &.{});
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try corpus_mod.load(gpa, io, roots, .contiguous);
    defer corpus.deinit();

    const sketches = kinship.buildSketches(gpa, corpus.docs);
    defer gpa.free(sketches);
    const silhouettes = kinship.buildSilhouettes(gpa, corpus.docs);
    defer gpa.free(silhouettes);
    const blob = try atlas_mod.save(gpa, corpus.paths, sketches, silhouettes, built_ns, roots);
    defer gpa.free(blob);
    // Spend is charged as the verb goes, in the order the tiers are worth
    // having: the atlas is what `similar` and `echoes` read at all, so it asks
    // first and the later tiers ask against what it took.
    var spent: u64 = 0;
    if (!affordable("atlas", blob.len, spent)) return;
    try frame.writeAtomic(io, atlas_mod.atlasFile(), blob);
    spent += blob.len;
    const atlas_dur = run.elapsed().ms();
    run.emit("atlas: {d} files · {d:.1} MiB corpus → {d:.1} MiB atlas · {d:.0} ms → {s}\n", .{
        corpus.docs.len,
        @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20),
        @as(f64, @floatFromInt(blob.len)) / (1 << 20),
        atlas_dur,
        atlas_mod.atlasFile(),
    }, .{
        .{ "artifact", "s", "atlas" },
        .{ "files", "d", corpus.docs.len },
        .{ "corpus_mib", "d:.1", @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20) },
        .{ "atlas_mib", "d:.1", @as(f64, @floatFromInt(blob.len)) / (1 << 20) },
        .{ "ms", "d:.0", atlas_dur },
        .{ "path", "s", atlas_mod.atlasFile() },
    });

    // The fragment tier rides the same corpus read + anchor: one silhouette per
    // extracted function, so `--unit function` answers warm.
    const frag_span = assay.Span.open(io);
    var fbuild = try frag_mod.buildAll(gpa, &corpus);
    defer fbuild.deinit();
    const fblob = try frag_mod.save(gpa, &fbuild, built_ns, roots);
    defer gpa.free(fblob);
    if (!affordable("frag", fblob.len, spent)) return;
    try frame.writeAtomic(io, frag_mod.fragFile(), fblob);
    spent += fblob.len;
    const frag_dur = frag_span.read(io).ms();
    run.emit("frag:  {d} fragment(s) → {d:.1} MiB · {d:.0} ms → {s}\n", .{
        fbuild.count(),
        @as(f64, @floatFromInt(fblob.len)) / (1 << 20),
        frag_dur,
        frag_mod.fragFile(),
    }, .{
        .{ "artifact", "s", "frag" },
        .{ "fragments", "d", fbuild.count() },
        .{ "frag_mib", "d:.1", @as(f64, @floatFromInt(fblob.len)) / (1 << 20) },
        .{ "ms", "d:.0", frag_dur },
        .{ "path", "s", frag_mod.fragFile() },
    });

    if (with_shelf) {
        // The shelf publishes itself, so its size is not in hand to charge.
        // The corpus is the ceiling on what a compressed copy of the corpus
        // can weigh, which is the conservative direction: the only error this
        // can make is declining a shelf that would have fitted, and losing it
        // costs `quote` and the exact-count tier — never an answer.
        if (!affordable("shelf", corpus.bytes, spent)) return;
        const shelf_span = assay.Span.open(io);
        const shelf = try shelf_mod.persist(gpa, io, corpus.docs, corpus.paths, built_ns);
        const shelf_dur = shelf_span.read(io).ms();
        run.emit("shelf: {d:.1} MiB ({d:.2} bits/char) · {d:.0} ms → {s}\n", .{
            @as(f64, @floatFromInt(shelf.bytes)) / (1 << 20),
            shelf.bits_per_char,
            shelf_dur,
            shelf_mod.shelfFile(),
        }, .{
            .{ "artifact", "s", "shelf" },
            .{ "shelf_mib", "d:.1", @as(f64, @floatFromInt(shelf.bytes)) / (1 << 20) },
            .{ "bits_per_char", "d:.2", shelf.bits_per_char },
            .{ "ms", "d:.0", shelf_dur },
            .{ "path", "s", shelf_mod.shelfFile() },
        });
    }
}

/// The refusal for a corpus with no edge — `$HOME`, a filesystem root — where
/// an index would take the whole machine as its subject (`irregex`'s
/// `index.home`). Exit 2, because there is no slower way to have an atlas and
/// a caller who asked for one is owed a straight answer; the read verbs keep
/// working here, live, exactly as they do without an atlas.
fn refuseUnbounded() !void {
    var here: [portal.max_path]u8 = undefined;
    const where = portal.realpath(".", &here) orelse "this directory";
    assay.diag("relate: index — {s} is not a project, and a corpus rooted here has no edge (it would be the whole machine)\n", .{where});
    assay.diag("relate: try   — cd into the directory you mean and run `relate index` there; the read verbs work here either way\n", .{});
    std.process.exit(2);
}

/// May this tier be written, given what the build has already spent of the
/// tree's disk allowance (`irregex`'s `index.allowance`)?
///
/// Declining is a `return`, not a fault: every verb these artifacts accelerate
/// has a live path that answers the same thing more slowly. It says so out
/// loud for the reason the whole family says so — a silently-unwritten
/// accelerator is indistinguishable from a slow tool.
fn affordable(tier: []const u8, want: u64, spent: u64) bool {
    if (allowance.admits(want, spent)) return true;
    assay.diag(
        "relate: note: {s} declined — {d} MiB does not fit what is left of the tree's {d} MiB artifact allowance ({d} MiB spent)\n" ++
            "relate: note: the verbs it accelerates still answer, live and slower (GIST_DISK_MB raises the allowance)\n",
        .{ tier, want >> 20, allowance.ceiling() >> 20, spent >> 20 },
    );
    return false;
}

fn fileBytes(io: std.Io, path: []const u8) ?u64 {
    const st = Dir.cwd().statFile(io, path, .{}) catch return null;
    return @intCast(st.size);
}

const Status = struct {
    schema_version: u8 = schema_version,
    atlas: struct {
        state: enum { ready, unavailable },
        files: usize = 0,
        bytes: u64 = 0,
        stale_files: usize = 0,
        built_unix_ns: i64 = 0,
    },
    frag: struct {
        state: enum { ready, unavailable },
        fragments: usize = 0,
        bytes: u64 = 0,
        stale_files: usize = 0,
        built_unix_ns: i64 = 0,
    },
    shelf: struct {
        state: enum { ready, unavailable },
        bytes: u64 = 0,
    },
};

/// `relate status [--json]` — atlas + shelf readiness. Exit 0 when the atlas
/// is ready (the kinship verbs run warm), 1 when it is missing/corrupt (they
/// still answer, live). Shelf detail beyond presence stays with
/// `gist codex status` — one artifact, one deep report.
pub fn runStatus(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const json = flags.onlyFlag(argv, "--json", "usage: relate status [--json]\n");

    var st = Status{
        .atlas = .{ .state = .unavailable },
        .frag = .{ .state = .unavailable },
        .shelf = .{ .state = .unavailable },
    };
    if (atlas_mod.loadQuiet(gpa, io)) |atl_v| {
        var atl = atl_v;
        defer atl.deinit(gpa);
        st.atlas = .{
            .state = .ready,
            .files = atl.paths.len,
            .bytes = fileBytes(io, atlas_mod.atlasFile()) orelse 0,
            .stale_files = fresh.staleCount(gpa, io, atl.roots, atl.built_ns),
            .built_unix_ns = atl.built_ns,
        };
    }
    if (frag_mod.loadQuiet(gpa, io)) |frag_v| {
        var f = frag_v;
        defer f.deinit(gpa);
        st.frag = .{
            .state = .ready,
            .fragments = f.spans.len,
            .bytes = fileBytes(io, frag_mod.fragFile()) orelse 0,
            .stale_files = fresh.staleCount(gpa, io, f.roots, f.built_ns),
            .built_unix_ns = f.built_ns,
        };
    }
    if (fileBytes(io, shelf_mod.shelfFile())) |b| st.shelf = .{ .state = .ready, .bytes = b };

    const shelf_line = if (st.shelf.state == .ready) "ready (quote answers)" else "missing — `relate index --shelf` builds it";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (json) {
        const body = try std.json.Stringify.valueAlloc(gpa, st, .{});
        defer gpa.free(body);
        try out.print(gpa, "{s}\n", .{body});
    } else if (st.atlas.state == .ready) {
        const frag_line = if (st.frag.state == .ready) "ready (--unit function answers warm)" else "missing — `relate index` builds it";
        try out.print(gpa,
            \\relate — kinship atlas {s}
            \\  files sketched  {d}
            \\  atlas           {d:.1} MiB
            \\  changed since   {d} file(s) (folded in at query time)
            \\  fragments       {d} · {d:.1} MiB · {d} changed — {s}
            \\  codex shelf     {s}
            \\
        , .{
            atlas_mod.atlasFile(),
            st.atlas.files,
            @as(f64, @floatFromInt(st.atlas.bytes)) / (1 << 20),
            st.atlas.stale_files,
            st.frag.fragments,
            @as(f64, @floatFromInt(st.frag.bytes)) / (1 << 20),
            st.frag.stale_files,
            frag_line,
            shelf_line,
        });
    } else {
        try out.print(gpa,
            \\relate — no kinship atlas at {s} (verbs answer live; `relate index` builds it)
            \\  codex shelf     {s}
            \\
        , .{ atlas_mod.atlasFile(), shelf_line });
    }
    corpus_mod.emitStdout(out.items);
    (Outcome{ .matched = st.atlas.state == .ready }).exit();
}
