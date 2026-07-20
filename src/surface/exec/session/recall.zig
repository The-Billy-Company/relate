//! relate resident retrieval session — the warm compression-search engine
//! (ADR-352 rung 2.5).
//!
//! A `RetrievalSession` holds one repository's mmap'd trigram index + doc→path
//! table warm across many `relate search`/`pack` queries, so an eligible
//! request pays neither the per-process index map nor the O(tree) freshness
//! stat walk — the two costs that dominate a cold `relate search`. It answers
//! through the SAME `retrieval.WarmQuery` kernel the one-shot CLI uses, handed
//! a `.resident` `Source`, so warm and cold answers cannot drift: the only
//! difference is who owns the index and whether the freshness walk runs.
//!
//! ## Freshness is anchor-based, so the overlay is cacheable
//!
//! Unlike gist's resident session — which mirrors live corpus BYTES and
//! reconciles a moving cursor — relate never holds file contents. Its freshness
//! is the persisted index's build ANCHOR (`fresh.readAnchor`): the set of files
//! whose mtime/ctime advanced at/after the build is exactly the set whose
//! persisted postings are stale. That set is a pure function of (index, tree
//! state), so it is recomputed only when the tree actually changes and reused
//! verbatim while the watcher proves the roots quiescent. The changed paths are
//! folded into an extension of the borrowed path table (session-owned strings)
//! exactly as the one-shot `fresh.widen` folds them, so `fresh_ids` name the
//! same docs a cold `relate search` would live-verify — warm==cold parity.
//!
//! ## Fail-closed, like every rung of this ladder
//!
//! The watcher is a pure accelerator (`watch.zig`): without one, or on any
//! doubt (queue overflow, an unwatchable new directory), the session simply
//! recomputes the overlay on every query — slower, never stale. A rebuilt index
//! (`pair.gen` drift) re-maps under the lock; a map failure leaves the session
//! intact and the query is declined (`null` → the client answers cold). Queries
//! are serialized by `mutex`; the watcher only ever touches the shared
//! `Seqlock` (`seqlock.zig`) + the `dirty_log`, so the barrier is a lock-free
//! seqlock over a mutex-guarded overlay.

const std = @import("std");
const fresh = @import("../../../corpus/index/trigrams/fresh.zig");
const persist = @import("../../../corpus/index/trigrams/persist.zig");
const dirtylog = @import("dirty.zig");
const Seqlock = @import("seqlock.zig").Seqlock;
const retrieval = @import("../cold/engine/retrieval.zig");
const Dir = std.Io.Dir;

pub const Result = retrieval.Result;
pub const PackResult = retrieval.PackResult;

pub const RetrievalSession = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    roots_arena: std.heap.ArenaAllocator,
    /// The roots the watcher covers (the CLI's cwd-rooted walk). `.` when empty,
    /// resolved by the watcher itself; queries carry their OWN roots argument.
    roots: []const []const u8,

    /// The warm, mmap'd index + doc→path table. Its `paths` list is EXTENDED in
    /// place past `base_len` with the freshness overlay's new-file paths (owned
    /// by `overlay_arena`); everything through `base_len` aliases the mmap.
    persisted: persist.Persisted,
    base_len: usize,
    /// Owns the changed-path strings appended to `persisted.paths`; reset (and
    /// its appends truncated away) at the head of every recompute.
    overlay_arena: std.heap.ArenaAllocator,
    /// Doc ids (into the extended path table) the freshness walk proved stale —
    /// the injected `Source.resident.fresh_ids` every query folds live. Cached
    /// across the whole clean window.
    fresh_ids: std.ArrayList(u32) = .empty,

    /// The index build instant; null when no trustworthy anchor exists (then no
    /// doc is provably fresh and the query trusts the index, exactly as the
    /// one-shot `fresh.candidates` no-anchor branch does).
    anchor_ns: ?i128,
    /// The published `pair.gen` this session bound to ("" = legacy/none); a
    /// change triggers a re-map.
    index_gen: []u8,

    mutex: std.Io.Mutex = .init,
    /// The freshness barrier shared with gist's `ResidentSession` — the
    /// watcher-driven seqlock whose memory ordering lives once in `seqlock.zig`.
    /// Without a live watcher it never proves clean, so every query recomputes
    /// the overlay (correct, just not microsecond-fast).
    seqlock: Seqlock = .{},
    /// The watcher's completeness hand-off. Relate's overlay is recomputed
    /// wholesale from the anchor, so the exact drained paths give no advantage
    /// over the clean/dirty bit — the log is drained (to consume it) and
    /// discarded. It exists to satisfy the shared watcher's contract.
    dirty_log: dirtylog.DirtyLog,
    daemon_gen: u64 = 0,

    /// Map the index warm. `null` when no index is built yet (the one expected
    /// miss — the client then answers cold).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !?RetrievalSession {
        var roots_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer roots_arena.deinit();
        const ra = roots_arena.allocator();
        const owned_roots = try ra.alloc([]const u8, roots.len);
        for (roots, 0..) |r, i| owned_roots[i] = try ra.dupe(u8, r);

        const p = (persist.loadQuiet(gpa, io) catch return null) orelse return null;
        const gen = readGen(gpa, io) catch {
            var tmp = p;
            tmp.deinit();
            return null;
        };
        return .{
            .gpa = gpa,
            .io = io,
            .roots_arena = roots_arena,
            .roots = owned_roots,
            .persisted = p,
            .base_len = p.paths.items.len,
            .overlay_arena = std.heap.ArenaAllocator.init(gpa),
            .anchor_ns = fresh.readAnchor(gpa, io),
            .index_gen = gen,
            .dirty_log = dirtylog.DirtyLog.init(gpa),
        };
    }

    pub fn deinit(self: *RetrievalSession) void {
        self.dirty_log.deinit();
        self.fresh_ids.deinit(self.gpa);
        self.gpa.free(self.index_gen);
        self.persisted.paths.shrinkRetainingCapacity(self.base_len); // drop overlay-arena aliases first
        self.overlay_arena.deinit();
        self.persisted.deinit();
        self.roots_arena.deinit();
    }

    // ── watcher hooks (called from the watch thread; lock-free) ──

    pub fn markDirty(self: *RetrievalSession) void {
        self.seqlock.markDirty();
    }

    pub fn markDoubtForever(self: *RetrievalSession) void {
        self.seqlock.markDoubtForever();
    }

    pub fn armWatcher(self: *RetrievalSession) void {
        self.seqlock.arm();
    }

    // ── freshness overlay ──

    /// Re-map the index when its on-disk generation advanced (someone ran `gist
    /// index`). Rare; holds the caller's lock. On failure the session keeps its
    /// old mapping and the query is declined (`null` → cold), so a rebuild never
    /// corrupts a live session.
    fn maybeReload(self: *RetrievalSession) !void {
        const cur = readGen(self.gpa, self.io) catch return error.Stale;
        defer self.gpa.free(cur);
        if (std.mem.eql(u8, cur, self.index_gen)) return;

        const np = (persist.loadQuiet(self.gpa, self.io) catch return error.Stale) orelse return error.Stale;
        // The old mapping's overlay aliases go first (they index the old table).
        self.persisted.paths.shrinkRetainingCapacity(self.base_len);
        _ = self.overlay_arena.reset(.free_all);
        self.fresh_ids.clearRetainingCapacity();
        self.persisted.deinit();
        self.gpa.free(self.index_gen);

        self.persisted = np;
        self.base_len = np.paths.items.len;
        self.anchor_ns = fresh.readAnchor(self.gpa, self.io);
        self.index_gen = self.gpa.dupe(u8, cur) catch return error.Stale;
        self.markDirty();
    }

    /// Bring the freshness overlay current. No-op on the watcher-clean fast path
    /// (the microsecond win — the cached `fresh_ids` still name every stale
    /// doc). Otherwise recompute: truncate the path table back to its mmap base,
    /// walk the anchor-relative changed set, and fold it back in exactly as the
    /// one-shot `fresh.candidates` does — so a resident answer and a cold
    /// `relate search` verify the identical doc set.
    fn reconcile(self: *RetrievalSession) !void {
        try self.maybeReload();
        if (self.seqlock.skip()) return;

        const seq0 = self.seqlock.enter();
        var drained = self.dirty_log.drain(self.gpa); // consume; anchor recompute ignores the paths
        drained.deinit(self.gpa);

        self.persisted.paths.shrinkRetainingCapacity(self.base_len);
        _ = self.overlay_arena.reset(.retain_capacity);
        self.fresh_ids.clearRetainingCapacity();
        if (self.anchor_ns) |anchor| {
            const a = self.overlay_arena.allocator();
            var changed: std.ArrayList([]const u8) = .empty;
            try fresh.changedSince(self.gpa, self.io, self.queryRoots(), anchor, a, &changed);
            if (changed.items.len > 0) {
                var scratch_ids: std.ArrayList(u32) = .empty;
                defer scratch_ids.deinit(self.gpa);
                try fresh.widen(self.gpa, &self.persisted.paths, &scratch_ids, &self.fresh_ids, changed.items);
            }
        }

        self.seqlock.commit(seq0);
    }

    /// The roots the freshness walk covers: the index's own build roots (the
    /// sound superset the overlay always folds over), never a re-derived guess.
    fn queryRoots(self: *const RetrievalSession) []const []const u8 {
        return self.persisted.roots.items;
    }

    fn source(self: *RetrievalSession) retrieval.Source {
        return .{ .resident = .{ .persisted = &self.persisted, .fresh_ids = self.fresh_ids.items } };
    }

    // ── the queries ──

    /// Answer `relate search` over the warm index. `roots` scopes the query
    /// (must be covered by the index); the caller owns the returned `Result`.
    /// `null` when the index cannot soundly cover the query (→ cold fallback).
    pub fn search(self: *RetrievalSession, gpa: std.mem.Allocator, query: []const u8, roots: []const []const u8, top: usize) !?Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reconcile() catch return null;
        return retrieval.retrieve(gpa, self.io, query, roots, top, self.source());
    }

    /// Answer `relate pack` over the warm index (see `search`).
    pub fn pack(self: *RetrievalSession, gpa: std.mem.Allocator, query: []const u8, roots: []const []const u8, top: usize) !?PackResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reconcile() catch return null;
        return retrieval.pack(gpa, self.io, query, roots, top, self.source());
    }
};

const readGen = persist.readPublishedGeneration;

test "resident session satisfies the shared freshness watcher contract" {
    // A compile-time proof that ONE generic watcher (`watch.zig`) drives both
    // gist's `ResidentSession` and this retrieval session: `refAllDecls` forces
    // the instantiation's method bodies to be analyzed against this session's
    // change-tracking surface (`roots`, `armWatcher`, `markDirty`,
    // `markDoubtForever`, `dirty_log.{armExact,note,noteDoubt}`). Missing or
    // mis-typed any of them and this test would fail to compile.
    const watch = @import("watch.zig");
    std.testing.refAllDecls(watch.Watcher(RetrievalSession));
}
