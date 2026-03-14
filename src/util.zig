const std = @import("std");

pub fn tupleLen(comptime t: anytype) usize {
    const info = @typeInfo(@TypeOf(t));
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("expected tuple");
    return info.@"struct".fields.len;
}

pub fn middlewareLookupName(comptime name: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(name))) {
        .enum_literal => @tagName(name),
        .pointer => |pointer| if (pointer.child == u8) name else @compileError("middleware name must be an enum literal or string"),
        .array => |array| if (array.child == u8) name[0..] else @compileError("middleware name must be an enum literal or string"),
        else => @compileError("middleware name must be an enum literal or string"),
    };
}
