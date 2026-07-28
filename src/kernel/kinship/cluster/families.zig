//! relate — union-find over the verified near-duplicate graph, the transitive
//! closure `--shape families` reports as fork families.
//!
//! Pure kernel: given the edges `pairs` verifies, `Forest` collapses connected
//! components with path-compressing finds and min-index roots. No ranks — the
//! find loop halves paths aggressively enough for these graph sizes, and
//! determinism comes from the driver's final sort, not the tree shape.

const std = @import("std");

pub const Forest = @import("../../math/forest.zig").Forest;

/// One admitted kinship edge over member indices, weighted by the channel
/// signal (byte/structure distance, or an echo gap) — the raw material the
/// component pass collapses into families.
pub const Edge = struct { i: u32, j: u32, w: f64 };

/// How a component summarizes the weights of its edges: `max` keeps the
/// loosest distance (dup/structure — a bigger distance is a looser edge),
/// `min` keeps the smallest echo gap (echo — a smaller gap is a looser edge).
pub const EdgeDir = enum { max, min };

/// One materialized family: member indices (path-asc) and the loosest edge
/// admitted into it.
pub const Group = struct { members: []u32, edge: f64 };

/// Collapse `edges` into families of ≥ `min_size` members via union-find, each
/// carrying its loosest edge under `dir`. `labels` (indexed by member id) give
/// the deterministic order: members sort path-asc within a family; families
/// sort size-desc then exemplar-path-asc. Singletons and sub-`min_size`
/// components are dropped. Caller frees each `members` slice and the list.
///
/// The shared component pass behind `relate echoes --shape families`, at every
/// unit and channel and with or without `--matching` — one union-find +
/// materialize, not one per verb that used to own a corner of this space.
pub fn components(
    gpa: std.mem.Allocator,
    labels: []const []const u8,
    edges: []const Edge,
    dir: EdgeDir,
    min_size: usize,
) ![]Group {
    const n = labels.len;
    var forest = try Forest.init(gpa, n);
    defer forest.deinit(gpa);
    for (edges) |e| forest.join(e.i, e.j);

    const Bucket = struct { members: std.ArrayList(u32) = .empty, edge: f64 = 0.0, seeded: bool = false };
    var roots: std.AutoArrayHashMapUnmanaged(u32, Bucket) = .empty;
    defer {
        for (roots.values()) |*b| b.members.deinit(gpa);
        roots.deinit(gpa);
    }
    for (edges) |e| {
        const gop = try roots.getOrPut(gpa, forest.find(e.i));
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .edge = e.w, .seeded = true };
        } else gop.value_ptr.edge = switch (dir) {
            .max => @max(gop.value_ptr.edge, e.w),
            .min => @min(gop.value_ptr.edge, e.w),
        };
    }
    for (0..n) |k| {
        const b = roots.getPtr(forest.find(@intCast(k))) orelse continue; // singleton: no verified edge
        try b.members.append(gpa, @intCast(k));
    }

    var list: std.ArrayList(Group) = .empty;
    errdefer {
        for (list.items) |g| gpa.free(g.members);
        list.deinit(gpa);
    }
    for (roots.values()) |*b| {
        if (b.members.items.len < min_size) continue;
        const members = try gpa.dupe(u32, b.members.items);
        std.mem.sort(u32, members, labels, memberLess);
        try list.append(gpa, .{ .members = members, .edge = b.edge });
    }
    std.mem.sort(Group, list.items, labels, groupLess);
    return list.toOwnedSlice(gpa);
}

fn memberLess(labels: []const []const u8, a: u32, b: u32) bool {
    return std.mem.order(u8, labels[a], labels[b]) == .lt;
}

fn groupLess(labels: []const []const u8, x: Group, y: Group) bool {
    if (x.members.len != y.members.len) return x.members.len > y.members.len; // size desc
    return std.mem.order(u8, labels[x.members[0]], labels[y.members[0]]) == .lt; // exemplar asc
}

const t = std.testing;

test "components: min-size gate, loosest edge, and total order" {
    const gpa = t.allocator;
    const labels = [_][]const u8{ "d.zig", "a.zig", "b.zig", "c.zig", "e.zig" };
    // a,b,c cluster (transitive); d,e a pair; distances vary so the loosest wins.
    const edges = [_]Edge{
        .{ .i = 1, .j = 2, .w = 0.10 }, // a-b
        .{ .i = 2, .j = 3, .w = 0.30 }, // b-c (loosest in this family)
        .{ .i = 0, .j = 4, .w = 0.05 }, // d-e
    };
    const groups = try components(gpa, &labels, &edges, .max, 2);
    defer {
        for (groups) |g| gpa.free(g.members);
        gpa.free(groups);
    }
    try t.expectEqual(@as(usize, 2), groups.len);
    // Bigger family first; members path-asc → a(1), b(2), c(3).
    try t.expectEqualSlices(u32, &.{ 1, 2, 3 }, groups[0].members);
    try t.expectEqual(@as(f64, 0.30), groups[0].edge); // loosest (max) edge kept
    try t.expectEqualSlices(u32, &.{ 0, 4 }, groups[1].members);

    // min echo gap wins under .min.
    const min_groups = try components(gpa, &labels, &edges, .min, 2);
    defer {
        for (min_groups) |g| gpa.free(g.members);
        gpa.free(min_groups);
    }
    try t.expectEqual(@as(f64, 0.10), min_groups[0].edge);
}

test "components: a below-min-size component is dropped, not surfaced" {
    const gpa = t.allocator;
    const labels = [_][]const u8{ "a", "b", "c" };
    const edges = [_]Edge{.{ .i = 0, .j = 1, .w = 0.2 }};
    const groups = try components(gpa, &labels, &edges, .max, 3); // needs 3, has 2
    defer gpa.free(groups);
    try t.expectEqual(@as(usize, 0), groups.len);
}
