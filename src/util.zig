const std = @import("std");

pub fn tupleLen(comptime t: anytype) usize {
    const info = @typeInfo(@TypeOf(t));
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("expected tuple");
    return info.@"struct".fields.len;
}

