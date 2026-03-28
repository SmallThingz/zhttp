const std = @import("std");
const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const core_util = @import("../util.zig");

pub const HeaderSetBehavior = enum {
    assert_absent,
    check_then_add,
};

/// Returns an owned header slice containing `base` followed by `extra`.
pub fn appendHeaders(
    allocator: std.mem.Allocator,
    base: []const Header,
    extra: []const Header,
) ![]const Header {
    if (extra.len == 0) return base;
    const out = try allocator.alloc(Header, base.len + extra.len);
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..], extra);
    return out;
}

/// Copies `src` into allocator-owned header storage.
pub fn copyHeaders(allocator: std.mem.Allocator, src: []const Header) ![]const Header {
    if (src.len == 0) return &.{};
    const out = try allocator.alloc(Header, src.len);
    @memcpy(out, src);
    return out;
}

/// Returns true when `headers` already contains `name` (case-insensitive).
pub fn hasHeader(headers: []const Header, name: []const u8) bool {
    for (headers) |h| {
        if (core_util.asciiEqlIgnoreCase(h.name, name)) return true;
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
        if (core_util.asciiEqlIgnoreCase(t, token)) return true;
    }
    return false;
}

/// Builds a quoted ETag from `body` using a Wyhash digest.
pub fn makeEtag(allocator: std.mem.Allocator, body: []const u8, weak: bool) ![]const u8 {
    const h = std.hash.Wyhash.hash(0, body);
    var tmp: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&tmp, "{x:0>16}", .{h}) catch unreachable;
    const extra: usize = if (weak) 4 else 2;
    const out = try allocator.alloc(u8, extra + hex.len);
    var i: usize = 0;
    if (weak) {
        out[i] = 'W';
        out[i + 1] = '/';
        i += 2;
    }
    out[i] = '"';
    i += 1;
    @memcpy(out[i .. i + hex.len], hex);
    i += hex.len;
    out[i] = '"';
    return out;
}

/// Matches an `If-None-Match` header value against `tag`.
pub fn matchesIfNoneMatch(header_value: []const u8, tag: []const u8) bool {
    const trimmed = std.mem.trim(u8, header_value, " \t");
    if (std.mem.eql(u8, trimmed, "*")) return true;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, t, "*")) return true;
        if (std.mem.eql(u8, t, tag)) return true;
        if (t.len > 2 and t[0] == 'W' and t[1] == '/' and std.mem.eql(u8, t[2..], tag)) return true;
    }
    return false;
}

test "appendHeaders: copies added headers when needed" {
    const base = [_]Header{.{ .name = "x-a", .value = "1" }};
    const extra = [_]Header{.{ .name = "x-b", .value = "2" }};

    const out1 = try appendHeaders(std.testing.allocator, base[0..], &.{});
    try std.testing.expectEqual(@as(usize, @intFromPtr(base[0..].ptr)), @as(usize, @intFromPtr(out1.ptr)));
    try std.testing.expectEqual(@as(usize, 1), out1.len);

    const out2 = try appendHeaders(std.testing.allocator, &.{}, extra[0..]);
    defer std.testing.allocator.free(out2);
    try std.testing.expect(out2.ptr != extra[0..].ptr);
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

test "matchesIfNoneMatch: strong, weak and wildcard tags" {
    try std.testing.expect(matchesIfNoneMatch("\"abc\"", "\"abc\""));
    try std.testing.expect(matchesIfNoneMatch("W/\"abc\"", "\"abc\""));
    try std.testing.expect(matchesIfNoneMatch("*, W/\"nope\"", "\"abc\""));
    try std.testing.expect(!matchesIfNoneMatch("\"nope\"", "\"abc\""));
}
