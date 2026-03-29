const std = @import("std");
const response = @import("response.zig");

/// Alias for response header entries used by upgrade helpers.
pub const Header = response.Header;
/// Alias for HTTP response type returned by upgrade helpers.
pub const Res = response.Res;

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Options for generic protocol-upgrade responses.
pub const ResponseOptions = struct {
    /// Value written to the `upgrade` header.
    protocol: []const u8,
    /// Extra headers appended after required `connection`/`upgrade` headers.
    extra_headers: []const Header = &.{},
};

/// Options for websocket upgrade responses.
pub const WebSocketResponseOptions = struct {
    /// Optional value written to `sec-websocket-protocol`.
    subprotocol: ?[]const u8 = null,
    /// Optional value written to `sec-websocket-extensions`.
    extensions: ?[]const u8 = null,
    /// Extra headers appended after websocket-required headers.
    extra_headers: []const Header = &.{},
};

/// Builds a generic `101 Switching Protocols` response.
pub fn responseFor(allocator: std.mem.Allocator, opts: ResponseOptions) !Res {
    if (opts.protocol.len == 0) return error.EmptyProtocol;

    const headers = try allocator.alloc(Header, 2 + opts.extra_headers.len);
    headers[0] = .{ .name = "connection", .value = "Upgrade" };
    headers[1] = .{ .name = "upgrade", .value = opts.protocol };
    for (opts.extra_headers, 0..) |h, i| {
        headers[2 + i] = h;
    }

    return .{
        .status = .switching_protocols,
        .headers = headers,
        .body = "",
    };
}

/// Computes the RFC 6455 `sec-websocket-accept` value for a websocket key.
pub fn websocketAcceptKey(allocator: std.mem.Allocator, sec_websocket_key: []const u8) ![]u8 {
    if (sec_websocket_key.len == 0) return error.EmptyWebSocketKey;

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(sec_websocket_key);
    sha1.update(websocket_guid);

    var digest: [20]u8 = undefined;
    sha1.final(&digest);

    const encoded_len = std.base64.standard.Encoder.calcSize(digest.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, &digest);
    return encoded;
}

fn websocketResponseFromOwnedAccept(
    allocator: std.mem.Allocator,
    accept: []u8,
    opts: WebSocketResponseOptions,
) !Res {
    // `accept` is already allocator-owned on entry, so this helper only needs
    // to splice it into the final header list and free it again if header
    // allocation fails.
    errdefer allocator.free(accept);

    var header_count: usize = 3 + opts.extra_headers.len;
    if (opts.subprotocol != null) header_count += 1;
    if (opts.extensions != null) header_count += 1;

    const headers = try allocator.alloc(Header, header_count);
    var n: usize = 0;
    headers[n] = .{ .name = "connection", .value = "Upgrade" };
    n += 1;
    headers[n] = .{ .name = "upgrade", .value = "websocket" };
    n += 1;
    headers[n] = .{ .name = "sec-websocket-accept", .value = accept };
    n += 1;

    if (opts.subprotocol) |subprotocol| {
        headers[n] = .{ .name = "sec-websocket-protocol", .value = subprotocol };
        n += 1;
    }
    if (opts.extensions) |extensions| {
        headers[n] = .{ .name = "sec-websocket-extensions", .value = extensions };
        n += 1;
    }
    for (opts.extra_headers) |h| {
        headers[n] = h;
        n += 1;
    }

    return .{
        .status = .switching_protocols,
        .headers = headers[0..n],
        .body = "",
    };
}

/// Builds a websocket `101 Switching Protocols` response.
pub fn websocketResponse(
    allocator: std.mem.Allocator,
    sec_websocket_key: []const u8,
    opts: WebSocketResponseOptions,
) !Res {
    const accept = try websocketAcceptKey(allocator, sec_websocket_key);
    return websocketResponseFromOwnedAccept(allocator, accept, opts);
}

/// Builds a websocket `101 Switching Protocols` response from a precomputed accept value.
pub fn websocketResponseWithAccept(
    allocator: std.mem.Allocator,
    sec_websocket_accept: []const u8,
    opts: WebSocketResponseOptions,
) !Res {
    if (sec_websocket_accept.len == 0) return error.EmptyWebSocketAccept;

    const accept = try allocator.dupe(u8, sec_websocket_accept);
    return websocketResponseFromOwnedAccept(allocator, accept, opts);
}

test "responseFor: generic upgrade headers are emitted" {
    const extra = [_]Header{.{ .name = "x-up", .value = "1" }};
    const res = try responseFor(std.testing.allocator, .{
        .protocol = "chat",
        .extra_headers = extra[0..],
    });
    defer std.testing.allocator.free(res.headers);

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expectEqualStrings("connection", res.headers[0].name);
    try std.testing.expectEqualStrings("Upgrade", res.headers[0].value);
    try std.testing.expectEqualStrings("upgrade", res.headers[1].name);
    try std.testing.expectEqualStrings("chat", res.headers[1].value);
    try std.testing.expectEqualStrings("x-up", res.headers[2].name);
    try std.testing.expectEqualStrings("1", res.headers[2].value);
}

test "responseFor: rejects empty protocol" {
    try std.testing.expectError(error.EmptyProtocol, responseFor(std.testing.allocator, .{
        .protocol = "",
    }));
}

test "websocketAcceptKey: matches RFC 6455 example" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = try websocketAcceptKey(std.testing.allocator, key);
    defer std.testing.allocator.free(accept);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "websocketAcceptKey: rejects empty key" {
    try std.testing.expectError(error.EmptyWebSocketKey, websocketAcceptKey(std.testing.allocator, ""));
}

test "websocketResponse: emits required websocket headers" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const res = try websocketResponse(std.testing.allocator, key, .{
        .subprotocol = "chat",
    });
    defer std.testing.allocator.free(res.headers);
    defer std.testing.allocator.free(res.headers[2].value);

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expectEqualStrings("connection", res.headers[0].name);
    try std.testing.expectEqualStrings("Upgrade", res.headers[0].value);
    try std.testing.expectEqualStrings("upgrade", res.headers[1].name);
    try std.testing.expectEqualStrings("websocket", res.headers[1].value);
    try std.testing.expectEqualStrings("sec-websocket-accept", res.headers[2].name);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", res.headers[2].value);
    try std.testing.expectEqualStrings("sec-websocket-protocol", res.headers[3].name);
    try std.testing.expectEqualStrings("chat", res.headers[3].value);
}

test "websocketResponseWithAccept: accepts precomputed value" {
    const res = try websocketResponseWithAccept(std.testing.allocator, "abc=", .{
        .extensions = "permessage-deflate",
        .extra_headers = &.{.{ .name = "x-up", .value = "1" }},
    });
    defer std.testing.allocator.free(res.headers);
    defer std.testing.allocator.free(res.headers[2].value);

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expectEqualStrings("sec-websocket-accept", res.headers[2].name);
    try std.testing.expectEqualStrings("abc=", res.headers[2].value);
    try std.testing.expectEqualStrings("sec-websocket-extensions", res.headers[3].name);
    try std.testing.expectEqualStrings("permessage-deflate", res.headers[3].value);
    try std.testing.expectEqualStrings("x-up", res.headers[4].name);
    try std.testing.expectEqualStrings("1", res.headers[4].value);
}

test "websocketResponseWithAccept: rejects empty accept value" {
    try std.testing.expectError(error.EmptyWebSocketAccept, websocketResponseWithAccept(std.testing.allocator, "", .{}));
}

test "websocketResponseWithAccept: omits optional websocket headers when absent" {
    const res = try websocketResponseWithAccept(std.testing.allocator, "abc=", .{});
    defer std.testing.allocator.free(res.headers);
    defer std.testing.allocator.free(res.headers[2].value);

    try std.testing.expectEqual(@as(usize, 3), res.headers.len);
    try std.testing.expectEqualStrings("connection", res.headers[0].name);
    try std.testing.expectEqualStrings("upgrade", res.headers[1].name);
    try std.testing.expectEqualStrings("sec-websocket-accept", res.headers[2].name);
}
