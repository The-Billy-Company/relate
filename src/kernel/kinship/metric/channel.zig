//! Kinship channels and their calibrated grades — the one vocabulary.
//!
//! A score is not an answer. `0.7813` looks like a result and reads like a
//! result; whether it MEANS "related" depends entirely on which question was
//! asked and how that question's scores distribute over a real corpus. This
//! module owns both halves of that judgment:
//!
//!   • **Channel** — which kinship question is being asked, named for what it
//!     finds rather than the metric it runs. Every face and every verb speaks
//!     these four words for pairwise kinship (`copies`, `twins`, `shapes`,
//!     `any`) and one for retrieval (`recall`).
//!
//!   • **Grade** — where a score falls on that channel's calibrated bands, so
//!     a caller can tell a real relation from statistical background.
//!
//! It lives in the kernel because calibration is a property of the metric, not
//! of a CLI: the repetition kernel needs the same bands the renderer prints.
//! `surface/cli/grade.zig` re-exports these and adds the stderr verdict.
//!
//! Cut points are measured, not chosen. Distances: 0.05 near-exact, 0.25 "same
//! thing, drifted" (the `dups` admission default), 0.50 "shares style, not
//! substance". Gaps: the 0.15 `--min-echo` floor, below which structural
//! closeness is small-sample noise. Recall gains, measured over this repo's
//! 20k-file corpus — a sentence lifted verbatim from a source file scored
//! 0.9496, an on-target descriptive query 0.63–0.82, an English query about a
//! subject the scope does not contain 0.32–0.44, and pure nonsense 0.16–0.23.

const std = @import("std");

/// Which kinship question a verb is answering. Tags are the user-facing
/// vocabulary; `metric` names the underlying channel for diagnostics.
pub const Channel = enum {
    /// LZJD distance over raw bytes — copy-paste and its drift.
    copies,
    /// byte distance − structure distance — the same skeleton wearing
    /// different vocabulary (Type-2 clones), the abstraction candidate.
    twins,
    /// Normalized-structure silhouette distance — shared skeleton, whether or
    /// not the vocabulary also matches.
    shapes,
    /// min(copies, shapes) — close in EITHER channel counts.
    any,
    /// Ziv–Merhav coding gain — how cheaply the corpus can express a TEXT
    /// probe. Not a pairwise channel: `score` has no definition for it (the
    /// retrieval engine prices it against a whole document), but it grades on
    /// bands like any other, so one `Verdict` covers probes of both kinds.
    recall,

    /// Which direction is "stronger" on this channel: a distance closes toward
    /// zero, while a gap and a coding gain both grow.
    pub const Polarity = enum { distance, stronger };

    pub fn polarity(self: Channel) Polarity {
        return switch (self) {
            .copies, .shapes, .any => .distance,
            .twins, .recall => .stronger,
        };
    }

    /// Is this a channel two records can be compared on? `recall` is not —
    /// it prices a text probe against one document.
    pub fn pairwise(self: Channel) bool {
        return self != .recall;
    }

    /// The underlying metric's name, for stderr diagnostics and prior-art
    /// cross-reference (the literature calls these LZJD / winnowed silhouette).
    pub fn metric(self: Channel) []const u8 {
        return switch (self) {
            .copies => "bytes",
            .twins => "echo",
            .shapes => "structure",
            .any => "fused",
            .recall => "gain",
        };
    }

    /// What a row's score column is called — the polarity, spelled. A distance
    /// channel reports `distance`, a gap reports `echo`, retrieval reports
    /// `gain`; calling all three "distance" in `--json` inverted the meaning of
    /// a threshold for anyone filtering rows downstream.
    pub fn quantity(self: Channel) []const u8 {
        return switch (self) {
            .copies, .shapes, .any => "distance",
            .twins => "echo",
            .recall => "gain",
        };
    }

    /// Combine a pair's two measured distances into this channel's score — the
    /// ONE definition of what each channel means in terms of the metrics.
    /// `copies` ignores `structure`, so a caller that never built silhouettes
    /// may pass anything for it. `recall` is not pairwise: it returns NaN,
    /// which grades `.none` rather than inventing a relation.
    pub fn score(self: Channel, bytes: f64, structure: f64) f64 {
        return switch (self) {
            .copies => bytes,
            .shapes => structure,
            .twins => bytes - structure,
            .any => @min(bytes, structure),
            .recall => std.math.nan(f64),
        };
    }

    /// Accept the user-facing vocabulary and the metric names it replaced, so
    /// a caller who learned `--lens bytes` is not stranded. One enum either
    /// way — the aliases are spellings, not a second code path.
    pub fn parse(s: []const u8) ?Channel {
        const table = .{
            .{ "copies", Channel.copies },  .{ "bytes", Channel.copies },
            .{ "twins", Channel.twins },    .{ "echo", Channel.twins },
            .{ "shapes", Channel.shapes },  .{ "structure", Channel.shapes },
            .{ "any", Channel.any },        .{ "fused", Channel.any },
            .{ "recall", Channel.recall },  .{ "gain", Channel.recall },
        };
        inline for (table) |row| if (std.mem.eql(u8, s, row[0])) return row[1];
        return null;
    }

    /// The channels a caller may name on `--as`: the pairwise four. `recall` is
    /// chosen by the probe's SHAPE (text, not a path), never by a flag, so it
    /// stays out of the flag's error message.
    pub const flag_values = "copies|twins|shapes|any";
};

/// Where a score falls on its channel's calibrated bands. Ordered strongest
/// first, so `@intFromEnum` ascending is confidence descending.
pub const Grade = enum {
    /// The same bytes, the same skeleton, or — on `recall` — text the corpus
    /// can already quote.
    identical,
    /// A real relation — the `--max-distance 0.25` band `dups` ships with.
    strong,
    /// Related, worth a look, not a fork.
    moderate,
    /// Past the line where kinship means "same language, same house style".
    weak,
    /// Background. Reporting this as a result is reporting noise.
    none,

    pub fn label(self: Grade) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Grade {
        return std.meta.stringToEnum(Grade, s);
    }

    /// Is `self` at least as strong as `floor`? The `--min-grade` predicate.
    pub fn meets(self: Grade, floor: Grade) bool {
        return @intFromEnum(self) <= @intFromEnum(floor);
    }
};

/// Grade `score` on `channel`'s bands. NaN — an unmeasured channel, or a
/// pairwise call on `recall` — is background, never a relation.
pub fn of(channel: Channel, score: f64) Grade {
    if (std.math.isNan(score)) return .none;
    return switch (channel) {
        .copies, .shapes, .any => if (score <= 0.05)
            .identical
        else if (score <= 0.25)
            .strong
        else if (score <= 0.50)
            .moderate
        else if (score <= 0.75)
            .weak
        else
            .none,
        // A gap can never mean "identical": two files with identical bytes
        // have a zero gap, which is the weakest twin signal there is.
        .twins => if (score >= 0.45)
            .strong
        else if (score >= 0.30)
            .moderate
        else if (score >= 0.15)
            .weak
        else
            .none,
        // Coding gain. The corpus quoting the probe back verbatim measured
        // 0.9496; an on-target paraphrase 0.63–0.82; an English query whose
        // subject is absent from the scope 0.32–0.44; nonsense under 0.24. A
        // one-word query is cheap to explain anywhere, which is why 0.43 for
        // `def` has to land in the same band as "not really here".
        .recall => if (score >= 0.90)
            .identical
        else if (score >= 0.60)
            .strong
        else if (score >= 0.45)
            .moderate
        else if (score >= 0.30)
            .weak
        else
            .none,
    };
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "one vocabulary: both spellings parse into the same channel" {
    try t.expectEqual(Channel.copies, Channel.parse("copies").?);
    try t.expectEqual(Channel.copies, Channel.parse("bytes").?);
    try t.expectEqual(Channel.twins, Channel.parse("twins").?);
    try t.expectEqual(Channel.twins, Channel.parse("echo").?);
    try t.expectEqual(Channel.shapes, Channel.parse("structure").?);
    try t.expectEqual(Channel.any, Channel.parse("fused").?);
    try t.expectEqual(Channel.recall, Channel.parse("gain").?);
    try t.expectEqual(@as(?Channel, null), Channel.parse("sideways"));
}

test "distance bands match the documented cut points" {
    try t.expectEqual(Grade.identical, of(.copies, 0.00));
    try t.expectEqual(Grade.identical, of(.copies, 0.05));
    try t.expectEqual(Grade.strong, of(.copies, 0.25)); // the dups default
    try t.expectEqual(Grade.moderate, of(.shapes, 0.50));
    try t.expectEqual(Grade.weak, of(.copies, 0.60)); // past "shares style, not substance"
    try t.expectEqual(Grade.weak, of(.copies, 0.75));
    // The measured `similar fresh.zig` nearest neighbor over 21091 files: far
    // enough out that calling it a neighbor at all is reporting background.
    try t.expectEqual(Grade.none, of(.copies, 0.7813));
}

test "gap bands invert, and a gap is never identical" {
    try t.expectEqual(Grade.strong, of(.twins, 0.6261)); // the schema.zig pair
    try t.expectEqual(Grade.moderate, of(.twins, 0.3655));
    try t.expectEqual(Grade.weak, of(.twins, 0.15)); // the --min-echo floor
    try t.expectEqual(Grade.none, of(.twins, 0.14));
    // Byte-identical files share every fingerprint, so their gap is zero —
    // the weakest twin evidence, not the strongest.
    try t.expectEqual(Grade.none, of(.twins, 0.0));
}

test "recall bands separate a quotation from a paraphrase from a stranger" {
    // Every cut point below is a measurement from this corpus, not a taste.
    try t.expectEqual(Grade.identical, of(.recall, 0.9496)); // lifted verbatim
    try t.expectEqual(Grade.strong, of(.recall, 0.8245)); // on-target paraphrase
    try t.expectEqual(Grade.strong, of(.recall, 0.6349));
    try t.expectEqual(Grade.weak, of(.recall, 0.4410)); // wallet query, irregex scope
    try t.expectEqual(Grade.weak, of(.recall, 0.4277)); // the one-word `def` query
    try t.expectEqual(Grade.none, of(.recall, 0.2316)); // nonsense
}

test "recall is not a pairwise channel and never fakes one" {
    try t.expect(!Channel.recall.pairwise());
    try t.expect(Channel.copies.pairwise());
    // Asked for a pair score anyway, it answers NaN — which grades as
    // background rather than as a suspiciously perfect 0.0 relation.
    try t.expect(std.math.isNan(Channel.recall.score(0.1, 0.2)));
    try t.expectEqual(Grade.none, of(.recall, Channel.recall.score(0.1, 0.2)));
}

test "polarity names the direction each channel improves in" {
    try t.expectEqual(Channel.Polarity.distance, Channel.copies.polarity());
    try t.expectEqual(Channel.Polarity.stronger, Channel.twins.polarity());
    try t.expectEqual(Channel.Polarity.stronger, Channel.recall.polarity());
    // The row's score column is named for what it measures, so a downstream
    // `--json` filter cannot invert a threshold by assuming "distance".
    try t.expectEqualStrings("distance", Channel.copies.quantity());
    try t.expectEqualStrings("echo", Channel.twins.quantity());
    try t.expectEqualStrings("gain", Channel.recall.quantity());
}

test "meets orders strongest-first for the --min-grade floor" {
    try t.expect(Grade.identical.meets(.strong));
    try t.expect(Grade.strong.meets(.strong));
    try t.expect(!Grade.moderate.meets(.strong));
    try t.expect(Grade.none.meets(.none));
}
