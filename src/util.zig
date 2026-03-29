const std = @import("std");

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

/// Computes a 64-bit FNV-1a hash.
pub fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

/// Returns the next power of two greater than or equal to `max(n, min)`.
pub fn nextPow2AtLeast(comptime n: usize, comptime min: usize) usize {
    var x: usize = if (n < min) min else n;
    x -= 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    if (@sizeOf(usize) == 8) x |= x >> 32;
    return x + 1;
}

test "tupleLen: empty and non-empty tuples" {
    try std.testing.expectEqual(@as(usize, 0), tupleLen(.{}));
    try std.testing.expectEqual(@as(usize, 3), tupleLen(.{ 1, true, "x" }));
}

test "ascii helpers: compare case-insensitively" {
    try std.testing.expectEqual(@as(u8, 'a'), asciiLower('A'));
    try std.testing.expectEqual(@as(u8, 'z'), asciiLower('z'));
    try std.testing.expectEqual(@as(u8, '-'), asciiLower('-'));
    try std.testing.expect(asciiEqlIgnoreCase("HeAdEr", "header"));
    try std.testing.expect(asciiEqlLower("ConNection", "connection"));
    try std.testing.expect(!asciiEqlLower("gzip", "br"));
}

test "hash and power-of-two helpers: stable outputs" {
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv1a64(""));
    try std.testing.expectEqual(@as(usize, 8), nextPow2AtLeast(5, 8));
    try std.testing.expectEqual(@as(usize, 16), nextPow2AtLeast(9, 8));
}
