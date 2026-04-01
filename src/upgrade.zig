const std = @import("std");
const response = @import("response.zig");
const request = @import("request.zig");
const parse = @import("parse.zig");
const zws = @import("zwebsocket");

/// Alias for response header entries used by upgrade helpers.
pub const Header = response.Header;
/// Alias for HTTP response type returned by upgrade helpers.
pub const Res = response.Res;
/// Standard websocket handshake header capture schema for route endpoints.
pub const WebSocketHeaders = struct {
    connection: parse.Optional(parse.String),
    upgrade: parse.Optional(parse.String),
    sec_websocket_key: parse.Optional(parse.String),
    sec_websocket_version: parse.Optional(parse.String),
    sec_websocket_protocol: parse.Optional(parse.String),
    sec_websocket_extensions: parse.Optional(parse.String),
    origin: parse.Optional(parse.String),
    host: parse.Optional(parse.String),
};
/// Alias for zwebsocket's server handshake request shape.
pub const WebSocketHandshakeRequest = zws.ServerHandshakeRequest;
/// Alias for zwebsocket's server handshake options.
pub const WebSocketHandshakeOptions = zws.ServerHandshakeOptions;
/// Alias for zwebsocket's server handshake response.
pub const WebSocketHandshakeResponse = zws.ServerHandshakeResponse;
/// Alias for zwebsocket's handshake validation errors.
pub const WebSocketHandshakeError = zws.HandshakeError;
pub const WebSocketRejectError = std.mem.Allocator.Error || WebSocketHandshakeError;

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

/// Builds a websocket handshake request view from a parsed zhttp request.
///
/// Routes using this helper should declare `Info.headers = zhttp.upgrade.WebSocketHeaders`
/// so every handshake field is available through `req.header(...)`.
///
/// Expected `req` shape:
/// - field `method: []const u8`
/// - `req.baseConst().version`
/// - `req.header(.connection/.upgrade/.sec_websocket_key/.sec_websocket_version/.sec_websocket_protocol/.sec_websocket_extensions/.origin/.host)`
pub fn websocketHandshakeRequest(req: anytype) WebSocketHandshakeRequest {
    return .{
        .method = req.method,
        .is_http_11 = req.baseConst().version == .http11,
        .connection = req.header(.connection),
        .upgrade = req.header(.upgrade),
        .sec_websocket_key = req.header(.sec_websocket_key),
        .sec_websocket_version = req.header(.sec_websocket_version),
        .sec_websocket_protocol = req.header(.sec_websocket_protocol),
        .sec_websocket_extensions = req.header(.sec_websocket_extensions),
        .origin = req.header(.origin),
        .host = req.header(.host),
    };
}

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

/// Builds a websocket `101 Switching Protocols` response from an accepted handshake.
pub fn websocketResponseFromAccepted(
    allocator: std.mem.Allocator,
    accepted: WebSocketHandshakeResponse,
) !Res {
    var header_count: usize = 3 + accepted.extra_headers.len;
    if (accepted.selected_subprotocol != null) header_count += 1;
    if (accepted.selected_extensions != null) header_count += 1;

    const accept = try allocator.dupe(u8, accepted.accept_key[0..]);
    errdefer allocator.free(accept);

    const headers = try allocator.alloc(Header, header_count);
    errdefer allocator.free(headers);

    var n: usize = 0;
    headers[n] = .{ .name = "connection", .value = "Upgrade" };
    n += 1;
    headers[n] = .{ .name = "upgrade", .value = "websocket" };
    n += 1;
    headers[n] = .{ .name = "sec-websocket-accept", .value = accept };
    n += 1;

    if (accepted.selected_subprotocol) |subprotocol| {
        headers[n] = .{ .name = "sec-websocket-protocol", .value = subprotocol };
        n += 1;
    }
    if (accepted.selected_extensions) |extensions| {
        headers[n] = .{ .name = "sec-websocket-extensions", .value = extensions };
        n += 1;
    }
    for (accepted.extra_headers) |h| {
        headers[n] = .{ .name = h.name, .value = h.value };
        n += 1;
    }

    return .{
        .status = .switching_protocols,
        .headers = headers[0..n],
        .body = "",
    };
}

/// Validates a websocket handshake and returns the corresponding `101` response.
///
/// Expected `req` shape:
/// - satisfies `websocketHandshakeRequest(req)` requirements
/// - exposes `req.allocator()`.
pub fn acceptWebSocket(
    req: anytype,
    opts: WebSocketHandshakeOptions,
) (std.mem.Allocator.Error || WebSocketHandshakeError)!Res {
    const accepted = try zws.acceptServerHandshake(websocketHandshakeRequest(req), opts);
    return websocketResponseFromAccepted(req.allocator(), accepted);
}

/// Maps websocket handshake/upgrade setup errors to standard HTTP responses.
pub fn rejectWebSocket(err: WebSocketRejectError) Res {
    return switch (err) {
        error.OutOfMemory => response.Res.text(500, "internal error\n"),
        error.UnsupportedWebSocketVersion => .{
            .status = @enumFromInt(426),
            .headers = &.{.{ .name = "sec-websocket-version", .value = "13" }},
            .body = "unsupported websocket version\n",
        },
        else => response.Res.text(400, "bad websocket handshake\n"),
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

test "websocketResponseFromAccepted: copies selected handshake outputs" {
    const FakeReq = struct {
        const Base = struct {
            version: request.Version = .http11,
        };

        base: Base = .{},
        method: []const u8 = "GET",

        pub fn baseConst(self: *const @This()) *const Base {
            return &self.base;
        }

        pub fn header(_: *const @This(), comptime field: anytype) ?[]const u8 {
            return switch (field) {
                .connection => "Upgrade",
                .upgrade => "websocket",
                .sec_websocket_key => "dGhlIHNhbXBsZSBub25jZQ==",
                .sec_websocket_version => "13",
                .sec_websocket_protocol => "chat, superchat",
                .sec_websocket_extensions => "permessage-deflate",
                .origin => "https://example.com",
                .host => "example.com",
                else => @compileError("unexpected header field"),
            };
        }
    };

    const req: FakeReq = .{};
    const accepted = try zws.acceptServerHandshake(websocketHandshakeRequest(&req), .{
        .selected_subprotocol = "chat",
        .enable_permessage_deflate = true,
        .extra_headers = &.{.{ .name = "x-up", .value = "1" }},
    });
    const res = try websocketResponseFromAccepted(std.testing.allocator, accepted);
    defer std.testing.allocator.free(res.headers);
    defer std.testing.allocator.free(res.headers[2].value);

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expectEqualStrings("connection", res.headers[0].name);
    try std.testing.expectEqualStrings("upgrade", res.headers[1].name);
    try std.testing.expectEqualStrings("sec-websocket-accept", res.headers[2].name);
    try std.testing.expectEqualStrings("sec-websocket-protocol", res.headers[3].name);
    try std.testing.expectEqualStrings("chat", res.headers[3].value);
    try std.testing.expectEqualStrings("sec-websocket-extensions", res.headers[4].name);
    try std.testing.expect(std.mem.startsWith(u8, res.headers[4].value, "permessage-deflate"));
    try std.testing.expectEqualStrings("x-up", res.headers[5].name);
    try std.testing.expectEqualStrings("1", res.headers[5].value);
}

test "websocketHandshakeRequest: extracts websocket headers from request" {
    const FakeReq = struct {
        const Base = struct {
            version: request.Version = .http11,
        };

        base: Base = .{},
        method: []const u8 = "GET",
        connection: ?[]const u8 = "keep-alive, Upgrade",
        upgrade_: ?[]const u8 = "websocket",
        key: ?[]const u8 = "dGhlIHNhbXBsZSBub25jZQ==",
        version_header: ?[]const u8 = "13",
        protocol: ?[]const u8 = "chat, superchat",
        extensions: ?[]const u8 = "permessage-deflate",
        origin: ?[]const u8 = "https://example.com",
        host: ?[]const u8 = "example.com",

        pub fn baseConst(self: *const @This()) *const Base {
            return &self.base;
        }

        pub fn header(self: *const @This(), comptime field: anytype) ?[]const u8 {
            return switch (field) {
                .connection => self.connection,
                .upgrade => self.upgrade_,
                .sec_websocket_key => self.key,
                .sec_websocket_version => self.version_header,
                .sec_websocket_protocol => self.protocol,
                .sec_websocket_extensions => self.extensions,
                .origin => self.origin,
                .host => self.host,
                else => @compileError("unexpected header field"),
            };
        }
    };

    const req: FakeReq = .{};
    const hs = websocketHandshakeRequest(&req);
    try std.testing.expectEqualStrings("GET", hs.method);
    try std.testing.expect(hs.is_http_11);
    try std.testing.expectEqualStrings("keep-alive, Upgrade", hs.connection.?);
    try std.testing.expectEqualStrings("websocket", hs.upgrade.?);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", hs.sec_websocket_key.?);
    try std.testing.expectEqualStrings("13", hs.sec_websocket_version.?);
    try std.testing.expectEqualStrings("chat, superchat", hs.sec_websocket_protocol.?);
    try std.testing.expectEqualStrings("permessage-deflate", hs.sec_websocket_extensions.?);
    try std.testing.expectEqualStrings("https://example.com", hs.origin.?);
    try std.testing.expectEqualStrings("example.com", hs.host.?);
}

test "acceptWebSocket: validates request and builds upgrade response" {
    const FakeReq = struct {
        const Base = struct {
            version: request.Version = .http11,
        };

        allocator_: std.mem.Allocator,
        base: Base = .{},
        method: []const u8 = "GET",

        pub fn allocator(self: *const @This()) std.mem.Allocator {
            return self.allocator_;
        }

        pub fn baseConst(self: *const @This()) *const Base {
            return &self.base;
        }

        pub fn header(_: *const @This(), comptime field: anytype) ?[]const u8 {
            return switch (field) {
                .connection => "Upgrade",
                .upgrade => "websocket",
                .sec_websocket_key => "dGhlIHNhbXBsZSBub25jZQ==",
                .sec_websocket_version => "13",
                .sec_websocket_protocol => "chat, superchat",
                .sec_websocket_extensions => null,
                .origin => "https://example.com",
                .host => "example.com",
                else => @compileError("unexpected header field"),
            };
        }
    };

    const req: FakeReq = .{ .allocator_ = std.testing.allocator };
    const res = try acceptWebSocket(&req, .{
        .selected_subprotocol = "chat",
        .extra_headers = &.{.{ .name = "x-up", .value = "1" }},
    });
    defer std.testing.allocator.free(res.headers);
    defer std.testing.allocator.free(res.headers[2].value);

    try std.testing.expectEqual(std.http.Status.switching_protocols, res.status);
    try std.testing.expectEqualStrings("sec-websocket-accept", res.headers[2].name);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", res.headers[2].value);
    try std.testing.expectEqualStrings("sec-websocket-protocol", res.headers[3].name);
    try std.testing.expectEqualStrings("chat", res.headers[3].value);
    try std.testing.expectEqualStrings("x-up", res.headers[4].name);
    try std.testing.expectEqualStrings("1", res.headers[4].value);
}

test "rejectWebSocket: maps websocket handshake failures to HTTP responses" {
    const bad = rejectWebSocket(error.InvalidUpgradeHeader);
    try std.testing.expectEqual(@as(u16, 400), @intFromEnum(bad.status));
    try std.testing.expectEqualStrings("bad websocket handshake\n", bad.body);

    const unsupported = rejectWebSocket(error.UnsupportedWebSocketVersion);
    try std.testing.expectEqual(@as(u16, 426), @intFromEnum(unsupported.status));
    try std.testing.expectEqualStrings("sec-websocket-version", unsupported.headers[0].name);
    try std.testing.expectEqualStrings("13", unsupported.headers[0].value);

    const oom = rejectWebSocket(error.OutOfMemory);
    try std.testing.expectEqual(@as(u16, 500), @intFromEnum(oom.status));
    try std.testing.expectEqualStrings("internal error\n", oom.body);
}
