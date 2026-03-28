const std = @import("std");

const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const parse = @import("../parse.zig");
const util = @import("util.zig");

fn makeEtag(allocator: std.mem.Allocator, body: []const u8, weak: bool) ![]const u8 {
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

fn matchesIfNoneMatch(header_value: []const u8, tag: []const u8) bool {
    const trimmed = std.mem.trim(u8, header_value, " \t");
    if (std.mem.eql(u8, trimmed, "*")) return true;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, t, tag)) return true;
        if (t.len > 2 and t[0] == 'W' and t[1] == '/' and std.mem.eql(u8, t[2..], tag)) return true;
    }
    return false;
}

pub fn Etag(comptime opts: anytype) type {
    const weak: bool = if (@hasField(@TypeOf(opts), "weak")) opts.weak else false;

    return struct {
        pub const Info = MiddlewareInfo{
            .name = "etag",
            .header = struct {
                if_none_match: parse.Optional(parse.String),
            },
        };

        pub fn call(comptime rctx: anytype, req: rctx.T()) !Res {
            var res = try rctx.next(req);
            if (res.body.len == 0) return res;
            if (util.hasHeader(res.headers, "etag")) return res;

            const tag = try makeEtag(req.allocator(), res.body, weak);
            if (req.header(.if_none_match)) |hdr| {
                if (matchesIfNoneMatch(hdr, tag)) {
                    return .{ .status = .not_modified, .headers = &.{.{ .name = "etag", .value = tag }}, .body = "" };
                }
            }

            res.headers = try util.appendHeaders(req.allocator(), res.headers, &.{.{ .name = "etag", .value = tag }});
            return res;
        }

        pub fn Override(comptime _: anytype) type {
            return struct {};
        }
    };
}

test "etag: matches if-none-match" {
    try std.testing.expect(matchesIfNoneMatch("\"abc\"", "\"abc\""));
    try std.testing.expect(matchesIfNoneMatch("W/\"abc\"", "\"abc\""));
    try std.testing.expect(matchesIfNoneMatch("*, W/\"nope\"", "\"abc\""));
    try std.testing.expect(!matchesIfNoneMatch("\"nope\"", "\"abc\""));
}
