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
/// Websocket handshake fields captured from request metadata.
pub const WebSocketHandshakeRequest = struct {
    /// Request method, expected to be `GET`.
    method: []const u8,
    /// Whether the parsed request version is HTTP/1.1.
    is_http_11: bool,
    /// `connection` request header.
    connection: ?[]const u8 = null,
    /// `upgrade` request header.
    upgrade: ?[]const u8 = null,
    /// `sec-websocket-key` request header.
    sec_websocket_key: ?[]const u8 = null,
    /// `sec-websocket-version` request header.
    sec_websocket_version: ?[]const u8 = null,
    /// `sec-websocket-protocol` request header.
    sec_websocket_protocol: ?[]const u8 = null,
    /// `sec-websocket-extensions` request header.
    sec_websocket_extensions: ?[]const u8 = null,
    /// `origin` request header.
    origin: ?[]const u8 = null,
    /// `host` request header.
    host: ?[]const u8 = null,
};
/// Options controlling websocket handshake acceptance.
pub const WebSocketHandshakeOptions = struct {
    /// Optional chosen subprotocol. Must be present in request offer list.
    selected_subprotocol: ?[]const u8 = null,
    /// Enables permessage-deflate negotiation based on request offers.
    enable_permessage_deflate: bool = false,
    /// Additional headers to append to the `101` response.
    extra_headers: []const Header = &.{},
};
/// Accepted websocket handshake output used to build a `101` response.
pub const WebSocketHandshakeResponse = struct {
    /// RFC 6455 computed accept value for `sec-websocket-accept`.
    accept_key: [28]u8,
    /// Optional selected websocket subprotocol.
    selected_subprotocol: ?[]const u8 = null,
    /// Optional negotiated extension response value.
    selected_extensions: ?[]const u8 = null,
    /// Extra headers preserved for the final `101` response.
    extra_headers: []const Header = &.{},
};
/// Errors returned while validating websocket handshake input.
pub const WebSocketHandshakeError = zws.Handshake.Error || error{
    SubprotocolNotOffered,
};
pub const WebSocketRejectError = std.mem.Allocator.Error || WebSocketHandshakeError;

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
    const accept = try zws.Handshake.computeAcceptKey(sec_websocket_key);
    return allocator.dupe(u8, accept[0..]);
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
    const accept = try allocator.dupe(u8, accepted.accept_key[0..]);
    return websocketResponseFromOwnedAccept(allocator, accept, .{
        .subprotocol = accepted.selected_subprotocol,
        .extensions = accepted.selected_extensions,
        .extra_headers = accepted.extra_headers,
    });
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
    const handshake = websocketHandshakeRequest(req);
    if (!std.mem.eql(u8, handshake.method, "GET")) return error.MethodNotGet;
    if (!handshake.is_http_11) return error.HttpVersionNotSupported;

    const connection = handshake.connection orelse return error.MissingConnectionHeader;
    var connection_tokens = std.mem.splitScalar(u8, connection, ',');
    while (connection_tokens.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), "upgrade")) break;
    } else return error.InvalidConnectionHeader;

    const upgrade_value = std.mem.trim(u8, handshake.upgrade orelse return error.MissingUpgradeHeader, " \t");
    if (!std.ascii.eqlIgnoreCase(upgrade_value, "websocket")) return error.InvalidUpgradeHeader;

    const key = std.mem.trim(u8, handshake.sec_websocket_key orelse return error.MissingWebSocketKey, " \t");
    const version = std.mem.trim(u8, handshake.sec_websocket_version orelse return error.MissingWebSocketVersion, " \t");
    if (!std.mem.eql(u8, version, "13")) return error.UnsupportedWebSocketVersion;

    if (opts.selected_subprotocol) |selected| {
        const offered = handshake.sec_websocket_protocol orelse return error.SubprotocolNotOffered;
        var offered_tokens = std.mem.splitScalar(u8, offered, ',');
        while (offered_tokens.next()) |part| {
            if (std.mem.eql(u8, std.mem.trim(u8, part, " \t"), selected)) break;
        } else return error.SubprotocolNotOffered;
    }

    const accept_key = try zws.Handshake.computeAcceptKey(key);
    const selected_extensions = if (opts.enable_permessage_deflate) blk: {
        const offered = handshake.sec_websocket_extensions orelse break :blk null;
        if (!zws.Extensions.offersPerMessageDeflate(offered)) break :blk null;

        const preferred: zws.Extensions.PerMessageDeflate = .{};
        var offers = zws.Extensions.parsePerMessageDeflate(offered);
        var negotiated: ?zws.Extensions.PerMessageDeflate = null;
        var best_score: usize = 0;
        // Multiple permessage-deflate offers are legal. Keep the best supported
        // alternative instead of requiring a single canonical ordering.
        while (offers.next() catch return error.ExtensionsNotSupported) |requested| {
            const score: usize = if (preferred.client_no_context_takeover and requested.client_no_context_takeover) 1 else 0;
            if (negotiated == null or score > best_score) {
                negotiated = .{
                    .server_no_context_takeover = preferred.server_no_context_takeover,
                    .client_no_context_takeover = preferred.client_no_context_takeover and requested.client_no_context_takeover,
                };
                best_score = score;
            }
        }
        if (negotiated) |selected| break :blk selected.responseHeaderValue();
        break :blk null;
    } else null;

    const accepted: WebSocketHandshakeResponse = .{
        .accept_key = accept_key,
        .selected_subprotocol = opts.selected_subprotocol,
        .selected_extensions = selected_extensions,
        .extra_headers = opts.extra_headers,
    };
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
    const accepted: WebSocketHandshakeResponse = .{
        .accept_key = try zws.Handshake.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ=="),
        .selected_subprotocol = "chat",
        .selected_extensions = "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
        .extra_headers = &.{.{ .name = "x-up", .value = "1" }},
    };
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

test "acceptWebSocket: rejects subprotocol selections not present in offers" {
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
    try std.testing.expectError(error.SubprotocolNotOffered, acceptWebSocket(&req, .{
        .selected_subprotocol = "json",
    }));
}

test "acceptWebSocket: negotiates permessage-deflate when enabled" {
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
                .sec_websocket_protocol => null,
                .sec_websocket_extensions => "permessage-deflate; client_no_context_takeover",
                .origin => "https://example.com",
                .host => "example.com",
                else => @compileError("unexpected header field"),
            };
        }
    };

    const req: FakeReq = .{ .allocator_ = std.testing.allocator };
    const res = try acceptWebSocket(&req, .{ .enable_permessage_deflate = true });
    defer std.testing.allocator.free(res.headers);
    defer std.testing.allocator.free(res.headers[2].value);

    try std.testing.expectEqual(@as(usize, 4), res.headers.len);
    try std.testing.expectEqualStrings("sec-websocket-extensions", res.headers[3].name);
    try std.testing.expect(std.mem.startsWith(u8, res.headers[3].value, "permessage-deflate"));
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
