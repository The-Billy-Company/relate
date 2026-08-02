//! Relate's C-ABI dispatch — one entry, one cursor.
//!
//! This module materializes a RELATE answer — kinship, retrieval, sweep —
//! into a pull cursor of self-describing `rows.Row`s. Twelve verbs share the
//! entry because a verb is a `u32` op plus one of three params families, so a
//! new verb adds no C symbol. Compose verbs live in `libblast`; `rank` lives
//! in `libgist`.
//!
//! The cursor itself (`Answer`) and the four walk symbols (`irgx_rows_*`)
//! live in `libirgx`. This module only produces: it builds an Answer, fills
//! the arena, and hands it over. A host walks it with the shared substrate.
//!
//! ## Declinature is a feature, not a stub
//!
//! A verb this build cannot answer in-process returns `.stale`, which the ABI
//! defines as *this tier declines — answer through the subprocess fallback, the
//! answer there is identical*. That is the same fail-open contract the exact
//! plane uses for a pattern outside linear syntax, and it is what lets the
//! plane graduate verb by verb without any binding changing a line: a binding
//! calls the FFI, reads `.stale`, and shells the CLI exactly as it does today.
//!
//! ## Why the answer is materialized whole
//!
//! An analytic verb has no meaningful partial state: `clusters` must see every
//! edge before it knows a component, `pack` prices each pick against the picks
//! before it. So the work runs to completion into one arena, and the cursor
//! walks a finished slice. Rows stay valid until `irgx_rows_close`.

const std = @import("std");
const api = @import("irregex").api;
const answer = @import("irregex").ffi.answer;
const contract = @import("irregex").ffi.contract;
const rows = @import("irregex").ffi.rows;

const Status = contract.Status;
const Row = rows.Row;
const Value = rows.Value;
const table = rows.table;
const Answer = answer.Answer;

/// What one dispatch arm is handed: the arena its rows must live in, the warm
/// engine, and the cancellation token the host may trip mid-answer.
const Ctx = struct {
    arena: std.mem.Allocator,
    engine: *api.Engine,
    cancel: ?*const api.CancelToken,
    out: *std.ArrayList(Row),
    stats: *rows.Stats,
};

/// `Decline` is the hosted spelling of `.stale`: not an error, a tier boundary.
const ArmError = error{ OutOfMemory, Decline };

fn owned(op: table.Op) bool {
    return switch (op) {
        .similar,
        .dups,
        .clusters,
        .echoes,
        .concepts,
        .fragments,
        .distinct,
        .recall,
        .pack,
        .quote,
        .patterns,
        .pattern_counts,
        => true,
        .context, .family, .provenance, .blast, .rank => false,
    };
}

/// Run one relate verb and materialize its cursor.
///
/// Fails closed before doing any work: an unknown op, an op this library does
/// not own, a params pointer of the wrong family or size, or an unassigned
/// flag bit is `.invalid` — never a reinterpret of memory the caller did not
/// write.
pub fn run(
    engine: *api.Engine,
    op: u32,
    params_ptr: ?*const rows.Params,
    cancel: ?*api.CancelToken,
    out: ?**Answer,
) Status {
    contract.beginCall();
    const slot = out orelse return .invalid;
    const params = params_ptr orelse return .invalid;
    if (op == 0 or op > table.verbs.len) return .invalid;
    const verb = table.verbs[op - 1];
    if (!owned(verb.op)) return .invalid;

    // The family check is the whole point of declaring `params` per verb: it
    // catches a host that passed `KinshipParams` to `pack` HERE, at the
    // boundary, instead of reading a `[*]const u8` out of an f64's bytes.
    switch (verb.params) {
        .kinship => if (rows.params(rows.KinshipParams, &params.kinship) == null) return .invalid,
        .retrieval => if (rows.params(rows.RetrievalParams, &params.retrieval) == null) return .invalid,
        .sweep => if (rows.params(rows.SweepParams, &params.sweep) == null) return .invalid,
        .compose, .rank => return .invalid,
    }

    const cursor = Answer.begin() catch return contract.report(.{ .code = error.OutOfMemory });
    errdefer answer.close(cursor);

    var collected: std.ArrayList(Row) = .empty;
    const started = std.Io.Clock.now(.awake, engine.io).nanoseconds;
    var st = rows.Stats{ .struct_size = @sizeOf(rows.Stats) };
    var ctx = Ctx{
        .arena = cursor.arena.allocator(),
        .engine = engine,
        .cancel = cancel,
        .out = &collected,
        .stats = &st,
    };

    dispatch(&ctx, verb, params) catch |err| switch (err) {
        error.Decline => {
            answer.close(cursor);
            return .stale;
        },
        error.OutOfMemory => return contract.report(.{ .code = error.OutOfMemory }),
    };

    const items = collected.toOwnedSlice(ctx.arena) catch
        return contract.report(.{ .code = error.OutOfMemory });
    st.rows = items.len;
    const elapsed = std.Io.Clock.now(.awake, engine.io).nanoseconds - started;
    st.elapsed_ns = if (elapsed > 0) @intCast(elapsed) else 0;
    cursor.finish(items, st);
    slot.* = cursor;
    return .ok;
}

/// The verb table's one switch. Every arm not yet in-process declines, so the
/// binding answers through the CLI and the caller sees the same rows.
fn dispatch(ctx: *Ctx, verb: table.Verb, params: *const rows.Params) ArmError!void {
    return switch (verb.op) {
        .patterns => sweepHits(ctx, &params.sweep),
        .pattern_counts => sweepCounts(ctx, &params.sweep),

        // Graduating in the analytic plane's staged order: the kinship family needs the
        // atlas resolve, retrieval the fingerprint lexicon.
        .similar,
        .dups,
        .clusters,
        .echoes,
        .concepts,
        .fragments,
        .distinct,
        .recall,
        .pack,
        .quote,
        => error.Decline,

        .context, .family, .provenance, .blast, .rank => unreachable,
    };
}

// ── the sweep family ────────────────────────────────────────────────────────
// N patterns, exact attribution. The verb's promise is *one corpus traversal
// per question set* rather than N cold walks — which a warm engine already
// satisfies structurally: the corpus, index, and mmaps stay resident across
// the loop, so each pattern pays a scan of memory the first one warmed, not a
// fresh tree walk. Attribution is exact by construction (the pattern index is
// the loop variable), which is the property `relate patterns` actually sells.

fn sweepQuery(p: *const rows.SweepParams, pattern: []const u8) api.SearchQuery {
    return .{
        .pattern = pattern,
        .fixed = p.flags & rows.an_fixed != 0,
        .ignore_case = p.flags & rows.an_ignore_case != 0,
    };
}

fn sweepPatterns(p: *const rows.SweepParams) []const rows.Text {
    if (p.npatterns == 0) return &.{};
    return (p.patterns orelse return &.{})[0..p.npatterns];
}

/// `patterns` — one `pattern_hit` row per matching line, attributed to the
/// pattern index that found it.
fn sweepHits(ctx: *Ctx, p: *const rows.SweepParams) ArmError!void {
    const patterns = sweepPatterns(p);
    if (patterns.len == 0) return error.Decline;
    const budget: usize = if (p.top == 0) std.math.maxInt(usize) else p.top;

    for (patterns, 0..) |pattern, index| {
        // One declined pattern makes the whole ANSWER declined: a partial sweep
        // silently missing a pattern's hits is worse than declining, because
        // the caller cannot tell the difference from a pattern that genuinely
        // matched nothing.
        var cursor = switch (try ctx.engine.search(sweepQuery(p, pattern.slice()), .{ .cancel = ctx.cancel })) {
            .declined => return error.Decline,
            .got => |c| c,
        };
        defer cursor.deinit();

        while (cursor.next()) |rec| {
            if (rec.kind != .match) continue;
            if (ctx.out.items.len >= budget) {
                ctx.stats.omitted += 1;
                continue;
            }
            var b = try rows.Builder.begin(ctx.arena, .pattern_hit);
            b.set(Value.text(try rows.dupe(ctx.arena, rec.path)));
            b.set(Value.int(@intCast(rec.line_number)));
            b.set(Value.int(@intCast(index)));
            try ctx.out.append(ctx.arena, b.end());
        }
    }
}

/// `pattern_counts` — engine-side totals, keyed by pattern (`an_by_pattern`,
/// the default) or by file (`an_by_file`). The point is to never cross the FFI
/// boundary once per hit when the caller only wants the tallies.
fn sweepCounts(ctx: *Ctx, p: *const rows.SweepParams) ArmError!void {
    const patterns = sweepPatterns(p);
    if (patterns.len == 0) return error.Decline;
    const by_file = p.flags & rows.an_by_file != 0;

    // Insertion-ordered so a tally set is deterministic across runs — a map's
    // iteration order would make two identical queries disagree.
    var labels: std.ArrayList([]const u8) = .empty;
    var counts: std.ArrayList(i64) = .empty;
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    defer seen.deinit(ctx.arena);

    for (patterns) |pattern| {
        var cursor = switch (try ctx.engine.search(sweepQuery(p, pattern.slice()), .{ .cancel = ctx.cancel })) {
            .declined => return error.Decline,
            .got => |c| c,
        };
        defer cursor.deinit();

        var tally: i64 = 0;
        while (cursor.next()) |rec| {
            if (rec.kind != .match) continue;
            if (!by_file) {
                tally += 1;
                continue;
            }
            const gop = try seen.getOrPut(ctx.arena, rec.path);
            if (gop.found_existing) {
                counts.items[gop.value_ptr.*] += 1;
            } else {
                // The map keys the arena copy, not the cursor's record: the
                // cursor's arena dies at the end of this iteration.
                const owned_path = try rows.dupe(ctx.arena, rec.path);
                gop.key_ptr.* = owned_path;
                gop.value_ptr.* = labels.items.len;
                try labels.append(ctx.arena, owned_path);
                try counts.append(ctx.arena, 1);
            }
        }
        if (!by_file) {
            try labels.append(ctx.arena, try rows.dupe(ctx.arena, pattern.slice()));
            try counts.append(ctx.arena, tally);
        }
    }

    for (labels.items, counts.items) |label, count| {
        var b = try rows.Builder.begin(ctx.arena, .pattern_count);
        b.set(Value.text(label));
        b.set(Value.int(count));
        try ctx.out.append(ctx.arena, b.end());
    }
}

test "an unknown op and a mismatched params family both fail closed" {
    const t = std.testing;
    // No engine is dereferenced on these paths — validation precedes work, by
    // design, so a bad call cannot reach the corpus at all.
    const engine: *api.Engine = @ptrFromInt(@alignOf(api.Engine));
    var out: *Answer = undefined;

    var params = rows.Params{
        .sweep = .{
            .struct_size = @sizeOf(rows.SweepParams),
            .flags = 0,
            .patterns = null,
            .npatterns = 0,
            .under = null,
            .under_len = 0,
            .top = 0,
            .reserved = 0,
        },
    };
    try t.expectEqual(Status.invalid, run(engine, 0, &params, null, &out));
    try t.expectEqual(Status.invalid, run(engine, table.verbs.len + 1, &params, null, &out));
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.patterns), &params, null, null));
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.patterns), null, null, &out));

    // `rank` is gist's verb: handed to relate_run, the ownership check rejects
    // it rather than declining into a CLI fallback for the wrong binary.
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.rank), &params, null, &out));

    // `similar` is a kinship verb: handed a sweep struct, the size check
    // rejects it rather than reading `npatterns` out of `max_distance`.
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.similar), &params, null, &out));

    params.sweep.flags = 1 << 30; // never assigned by this build
    try t.expectEqual(Status.invalid, run(engine, @intFromEnum(table.Op.patterns), &params, null, &out));
}

test "every relate verb is either dispatched or declines — none can fall through" {
    // A `switch` over the owned ops with no `else` makes this structural:
    // adding a verb to this library's set fails the BUILD until this file
    // names it. The test pins that the global table still enumerates every
    // op, including the ones other libraries own.
    const t = std.testing;
    for (table.verbs, 1..) |verb, op| {
        try t.expectEqual(@as(u32, @intCast(op)), @intFromEnum(verb.op));
        try t.expect(@intFromEnum(verb.schema) >= 1 and @intFromEnum(verb.schema) <= table.schemas.len);
    }
}
