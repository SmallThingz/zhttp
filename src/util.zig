const std = @import("std");

/// Implements tuple len.
pub fn tupleLen(comptime t: anytype) usize {
    const info = @typeInfo(@TypeOf(t));
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("expected tuple");
    return info.@"struct".fields.len;
}

/// Lowercases one ASCII byte and leaves everything else unchanged.
pub fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

/// Compares two ASCII strings ignoring case.
pub fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |lhs, rhs| {
        if (asciiLower(lhs) != asciiLower(rhs)) return false;
    }
    return true;
}

/// Compares `value` against a lowercase ASCII string ignoring case.
pub fn asciiEqlLower(value: []const u8, comptime lower: []const u8) bool {
    if (value.len != lower.len) return false;
    for (value, lower) |lhs, rhs| {
        if (asciiLower(lhs) != rhs) return false;
    }
    return true;
}

test "tupleLen: empty and non-empty tuples" {
    try std.testing.expectEqual(@as(usize, 0), tupleLen(.{}));
    try std.testing.expectEqual(@as(usize, 3), tupleLen(.{ 1, true, "x" }));
}

test "ascii helpers: compare case-insensitively" {
    try std.testing.expect(asciiEqlIgnoreCase("HeAdEr", "header"));
    try std.testing.expect(asciiEqlLower("ConNection", "connection"));
    try std.testing.expect(!asciiEqlLower("gzip", "br"));
}
