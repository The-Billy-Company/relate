//! The source-token vocabulary — what counts as an identifier byte, and the
//! maximal-identifier scan built on it. One definition, shared: anatomy's
//! dependency rows (`leans`) and kinship's structure fingerprints
//! (`silhouette`) must agree about token boundaries, or the two planes
//! silently disagree about what a name is.

const std = @import("std");

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
pub fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The next maximal identifier in `text` at/after `i`, advancing `i` past it.
pub fn nextIdent(text: []const u8, i: *usize) ?[]const u8 {
    while (i.* < text.len and !isIdentStart(text[i.*])) i.* += 1;
    if (i.* >= text.len) return null;
    const start = i.*;
    while (i.* < text.len and isIdentByte(text[i.*])) i.* += 1;
    return text[start..i.*];
}
