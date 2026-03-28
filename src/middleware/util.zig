const std = @import("std");
const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;

pub const HeaderSetBehavior = enum {
    assert_absent,
    check_then_add,
};

/// Returns `base` with `extra` appended as a single header slice.
pub fn appendHeaders(
    allocator: std.mem.Allocator,
    base: []const Header,
    extra: []const Header,
) ![]const Header {
    if (extra.len == 0) return base;
    if (base.len == 0) return extra;
    const out = try allocator.alloc(Header, base.len + extra.len);
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..], extra);
    return out;
}

/// Returns true when `headers` already contains `name` (case-insensitive).
pub fn hasHeader(headers: []const Header, name: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}

/// Applies configured duplicate-header behavior and reports whether to add `name`.
pub fn shouldAddHeader(headers: []const Header, name: []const u8, behavior: HeaderSetBehavior) bool {
    return switch (behavior) {
        .assert_absent => blk: {
            std.debug.assert(!hasHeader(headers, name));
            break :blk true;
        },
        .check_then_add => !hasHeader(headers, name),
    };
}

/// Joins `items` into a single comma-separated header value.
pub fn joinCommaList(
    allocator: std.mem.Allocator,
    items: []const []const u8,
) ![]const u8 {
    if (items.len == 0) return "";
    if (items.len == 1) return items[0];
    var total: usize = 0;
    for (items) |s| total += s.len;
    total += (items.len - 1) * 2; // ", "
    const out = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (items, 0..) |s, i| {
        if (i != 0) {
            out[off] = ',';
            out[off + 1] = ' ';
            off += 2;
        }
        @memcpy(out[off .. off + s.len], s);
        off += s.len;
    }
    return out;
}

/// Returns true when `value` contains `token` in a comma-separated token list.
pub fn hasToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (std.ascii.eqlIgnoreCase(t, token)) return true;
    }
    return false;
}

test "appendHeaders: short-circuits empty slices" {
    const base = [_]Header{.{ .name = "x-a", .value = "1" }};
    const extra = [_]Header{.{ .name = "x-b", .value = "2" }};

    const out1 = try appendHeaders(std.testing.allocator, base[0..], &.{});
    try std.testing.expectEqual(@as(usize, @intFromPtr(base[0..].ptr)), @as(usize, @intFromPtr(out1.ptr)));
    try std.testing.expectEqual(@as(usize, 1), out1.len);

    const out2 = try appendHeaders(std.testing.allocator, &.{}, extra[0..]);
    try std.testing.expectEqual(@as(usize, @intFromPtr(extra[0..].ptr)), @as(usize, @intFromPtr(out2.ptr)));
    try std.testing.expectEqual(@as(usize, 1), out2.len);
}

test "appendHeaders: concatenates in order" {
    const base = [_]Header{.{ .name = "x-a", .value = "1" }};
    const extra = [_]Header{
        .{ .name = "x-b", .value = "2" },
        .{ .name = "x-c", .value = "3" },
    };
    const out = try appendHeaders(std.testing.allocator, base[0..], extra[0..]);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("x-a", out[0].name);
    try std.testing.expectEqualStrings("x-b", out[1].name);
    try std.testing.expectEqualStrings("x-c", out[2].name);
}

test "shouldAddHeader: check_then_add is case-insensitive" {
    const headers = [_]Header{
        .{ .name = "X-Token", .value = "abc" },
    };
    try std.testing.expect(!shouldAddHeader(headers[0..], "x-token", .check_then_add));
    try std.testing.expect(shouldAddHeader(headers[0..], "x-other", .check_then_add));
}

test "joinCommaList: supports zero one and many entries" {
    const empty = try joinCommaList(std.testing.allocator, &.{});
    try std.testing.expectEqualStrings("", empty);

    const single_items = [_][]const u8{"gzip"};
    const single = try joinCommaList(std.testing.allocator, single_items[0..]);
    try std.testing.expectEqualStrings("gzip", single);

    const multi_items = [_][]const u8{ "gzip", "br", "deflate" };
    const multi = try joinCommaList(std.testing.allocator, multi_items[0..]);
    defer std.testing.allocator.free(multi);
    try std.testing.expectEqualStrings("gzip, br, deflate", multi);
}

test "hasToken: trims tokens and ignores case" {
    try std.testing.expect(hasToken("gzip, deflate, br", "BR"));
    try std.testing.expect(hasToken(" gzip ,\tdeflate\t", "deflate"));
    try std.testing.expect(!hasToken("gzip,br", "zstd"));
}
