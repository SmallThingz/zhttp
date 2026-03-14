const std = @import("std");
const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;

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

pub fn hasHeader(headers: []const Header, name: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}

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

pub fn hasToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (std.ascii.eqlIgnoreCase(t, token)) return true;
    }
    return false;
}
