const std = @import("std");

/// Implements tuple len.
pub fn tupleLen(comptime t: anytype) usize {
    const info = @typeInfo(@TypeOf(t));
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("expected tuple");
    return info.@"struct".fields.len;
}

test "tupleLen: empty and non-empty tuples" {
    try std.testing.expectEqual(@as(usize, 0), tupleLen(.{}));
    try std.testing.expectEqual(@as(usize, 3), tupleLen(.{ 1, true, "x" }));
}
