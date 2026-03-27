const std = @import("std");
const zhttp = @import("zhttp");
const builtin = @import("builtin");
const scripts = @import("scripts.zig");

const Io = std.Io;

const Mode = enum {
    zhttp,
    external,
};

const Config = struct {
    mode: Mode = .external,
    host: []const u8 = "127.0.0.1",
    port: u16 = 0,
    path: []const u8 = "/plaintext",
    conns: usize = 1,
    iters: u64 = 200_000,
    warmup: u64 = 10_000,
    fixed_bytes: ?usize = null,
    minimal_request: bool = true,
    quiet: bool = false,
};

const ConnResult = struct {
    completed: u64 = 0,
    err: ?anyerror = null,
};

const ConnState = struct {
    stream: std.Io.net.Stream = undefined,
    read_buf: []u8 = &.{},
    write_buf: []u8 = &.{},
    result: ConnResult = .{},
};

fn setTcpNoDelay(stream: *const std.Io.net.Stream) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    var one: i32 = 1;
    std.posix.setsockopt(
        stream.socket.handle,
        @intCast(linux.IPPROTO.TCP),
        linux.TCP.NODELAY,
        std.mem.asBytes(&one),
    ) catch {};
}

fn usage() void {
    std.debug.print(
        \\zhttp-bench
        \\
        \\Usage:
        \\  zig build bench -Doptimize=ReleaseFast -- [options]
        \\
        \\Modes:
        \\  --mode=zhttp        Run an in-process zhttp server
        \\  --mode=external     Benchmark an external server (default)
        \\
        \\Options:
        \\  --host=127.0.0.1    IPv4 literal (external mode)
        \\  --port=8080         Port (external mode; zhttp mode uses 0 by default)
        \\  --path=/plaintext   Request path
        \\  --conns=1           Concurrent connections
        \\  --iters=200000      Requests per connection
        \\  --warmup=10000      Warmup requests per connection
        \\  --fixed-bytes=N     Skip auto-discovery; discard exactly N bytes/response
        \\  --full-request      Send Host/Connection headers (default is minimal request)
        \\  --quiet             Print a single summary line
        \\  --help              Show this help
        \\
    , .{});
}

fn parseMode(s: []const u8) !Mode {
    if (std.mem.eql(u8, s, "zhttp")) return .zhttp;
    if (std.mem.eql(u8, s, "external")) return .external;
    return error.BadMode;
}

fn parseBoolFlag(arg: []const u8, comptime name: []const u8) bool {
    return std.mem.eql(u8, arg, "--" ++ name);
}

fn trimLeftSpaceTab(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |c, i| {
        const hc = haystack[i];
        if (std.ascii.toLower(hc) != std.ascii.toLower(c)) return false;
    }
    return true;
}

fn discardExact(r: *Io.Reader, n: usize) !void {
    var remaining = n;
    while (remaining != 0) {
        const got = try r.discard(.limited(remaining));
        if (got == 0) return error.EndOfStream;
        remaining -= got;
    }
}

fn discoverFixedResponseBytes(io: Io, address: std.Io.net.IpAddress, request_bytes: []const u8) !usize {
    var stream = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    defer stream.close(io);
    setTcpNoDelay(&stream);

    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [2048]u8 = undefined;

    var sr = stream.reader(io, &read_buf);
    var sw = stream.writer(io, &write_buf);

    try sw.interface.writeAll(request_bytes);
    try sw.interface.flush();

    var header_bytes: usize = 0;
    var content_length: ?usize = null;

    while (true) {
        const line0_incl = sr.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
        header_bytes += line0_incl.len;
        const line0 = line0_incl[0 .. line0_incl.len - 1];
        const line = scripts.trimCR(line0);
        if (line.len == 0) break;

        if (asciiStartsWithIgnoreCase(line, "content-length:")) {
            var v = line["content-length:".len..];
            v = trimLeftSpaceTab(v);
            content_length = try std.fmt.parseInt(usize, v, 10);
        }
    }

    const body_len = content_length orelse return error.MissingContentLength;
    try discardExact(&sr.interface, body_len);
    return header_bytes + body_len;
}

fn benchConn(io: Io, state: *ConnState, request_bytes: []const u8, fixed_bytes: usize, iters: u64) Io.Cancelable!void {
    var sr = state.stream.reader(io, state.read_buf);
    var sw = state.stream.writer(io, state.write_buf);
    defer state.stream.close(io);

    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        sw.interface.writeAll(request_bytes) catch |err| {
            state.result.err = err;
            return;
        };
        sw.interface.flush() catch |err| {
            state.result.err = err;
            return;
        };
        discardExact(&sr.interface, fixed_bytes) catch |err| {
            state.result.err = err;
            return;
        };
        state.result.completed += 1;
    }
}

fn buildRequest(a: std.mem.Allocator, host: []const u8, path: []const u8) ![]const u8 {
    _ = host;
    return std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\n\r\n", .{path});
}

fn buildFullRequest(a: std.mem.Allocator, host: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        a,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n",
        .{ path, host },
    );
}

fn connectAndWarmup(
    a: std.mem.Allocator,
    io: Io,
    address: std.Io.net.IpAddress,
    states: []ConnState,
    request_bytes: []const u8,
    fixed_bytes: usize,
    warmup: u64,
) !void {
    for (states) |*st| {
        st.read_buf = try a.alloc(u8, 64 * 1024);
        st.write_buf = try a.alloc(u8, 4096);
        st.stream = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
        setTcpNoDelay(&st.stream);

        if (warmup != 0) {
            var sr = st.stream.reader(io, st.read_buf);
            var sw = st.stream.writer(io, st.write_buf);

            var i: u64 = 0;
            while (i < warmup) : (i += 1) {
                try sw.interface.writeAll(request_bytes);
                try sw.interface.flush();
                try discardExact(&sr.interface, fixed_bytes);
            }
        }
    }
}

fn freeStates(a: std.mem.Allocator, states: []ConnState) void {
    for (states) |*st| {
        if (st.read_buf.len != 0) a.free(st.read_buf);
        if (st.write_buf.len != 0) a.free(st.write_buf);
        st.* = undefined;
    }
}

fn runBenchmark(init: std.process.Init, address: std.Io.net.IpAddress, request_bytes: []const u8, fixed_bytes: usize, cfg: Config) !void {
    const a = init.gpa;

    const states = try a.alloc(ConnState, cfg.conns);
    defer a.free(states);
    @memset(states, .{});
    defer freeStates(a, states);

    try connectAndWarmup(a, init.io, address, states, request_bytes, fixed_bytes, cfg.warmup);

    var group: Io.Group = .init;
    defer group.cancel(init.io);

    const start = Io.Clock.Timestamp.now(init.io, .awake);
    for (states) |*st| {
        try group.concurrent(init.io, benchConn, .{ init.io, st, request_bytes, fixed_bytes, cfg.iters });
    }
    group.await(init.io) catch {};
    const end = Io.Clock.Timestamp.now(init.io, .awake);

    var total_ok: u64 = 0;
    var first_err: ?anyerror = null;
    for (states) |st| {
        total_ok += st.result.completed;
        if (first_err == null and st.result.err != null) first_err = st.result.err;
    }

    const elapsed = start.durationTo(end);
    const elapsed_ns_i96 = elapsed.raw.nanoseconds;
    const elapsed_ns: u64 = @intCast(@max(elapsed_ns_i96, 0));
    const secs: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const rps: f64 = if (secs == 0) 0 else @as(f64, @floatFromInt(total_ok)) / secs;
    const ns_per_req: f64 = if (total_ok == 0) 0 else @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_ok));
    const mib_per_s: f64 = if (secs == 0) 0 else (@as(f64, @floatFromInt(total_ok)) * @as(f64, @floatFromInt(fixed_bytes))) / (1024.0 * 1024.0) / secs;
    const prefix: []const u8 = if (init.environ_map.get("BENCH_LABEL")) |lbl|
        lbl
    else if (cfg.mode == .zhttp)
        "zhttp "
    else
        "";

    if (!cfg.quiet) {
        std.debug.print("{s}conns={d} iters={d} warmup={d} fixed_bytes={d}\n", .{ prefix, cfg.conns, cfg.iters, cfg.warmup, fixed_bytes });
        std.debug.print("{s}ok={d} elapsed_ns={d}\n", .{ prefix, total_ok, elapsed_ns });
        std.debug.print("{s}req/s={d:.2} ns/req={d:.1} MiB/s={d:.2}\n", .{ prefix, rps, ns_per_req, mib_per_s });
        if (first_err) |e| std.debug.print("first_error={s}\n", .{@errorName(e)});
    } else {
        std.debug.print("{s}ok={d} elapsed_ns={d} fixed_bytes={d} req/s={d:.2} ns/req={d:.1} MiB/s={d:.2}\n", .{ prefix, total_ok, elapsed_ns, fixed_bytes, rps, ns_per_req, mib_per_s });
        if (first_err) |e| std.debug.print("first_error={s}\n", .{@errorName(e)});
    }
}

fn plaintext() !zhttp.Res {
    const body = "Hello, World!";
    return .{
        .status = 200,
        .headers = &.{
            .{ .name = "Server", .value = "F" },
            .{ .name = "Content-Type", .value = "text/plain" },
            .{ .name = "Date", .value = "Wed, 24 Feb 2021 12:00:00 GMT" },
        },
        .body = body,
    };
}

fn runZhttp(init: std.process.Init, cfg: Config) !void {
    const SrvT = zhttp.Server(.{
        .routes = .{
            zhttp.get("/plaintext", plaintext, .{}),
        },
        .config = .{},
    });

    const bind_port: u16 = cfg.port; // default 0 (ephemeral)
    const bind_addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(bind_port) };
    var server = try SrvT.init(init.gpa, init.io, bind_addr, {});
    defer server.deinit();

    const actual_port: u16 = server.listener.socket.address.getPort();
    if (actual_port == 0) return error.FailedToBindPort;

    var server_group: Io.Group = .init;
    defer server_group.cancel(init.io);
    try server_group.concurrent(init.io, SrvT.run, .{&server});

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(actual_port) };
    const host = "127.0.0.1";
    const request_bytes = if (cfg.minimal_request)
        try buildRequest(init.arena.allocator(), host, cfg.path)
    else
        try buildFullRequest(init.arena.allocator(), host, cfg.path);
    const fixed_bytes = cfg.fixed_bytes orelse try discoverFixedResponseBytes(init.io, addr, request_bytes);
    try runBenchmark(init, addr, request_bytes, fixed_bytes, cfg);

    server_group.cancel(init.io);
    server_group.await(init.io) catch {};
}

fn runExternal(init: std.process.Init, cfg: Config) !void {
    const ip4 = try std.Io.net.Ip4Address.parse(cfg.host, cfg.port);
    const addr: std.Io.net.IpAddress = .{ .ip4 = ip4 };
    const request_bytes = if (cfg.minimal_request)
        try buildRequest(init.arena.allocator(), cfg.host, cfg.path)
    else
        try buildFullRequest(init.arena.allocator(), cfg.host, cfg.path);

    const fixed_bytes = cfg.fixed_bytes orelse try discoverFixedResponseBytes(init.io, addr, request_bytes);
    try runBenchmark(init, addr, request_bytes, fixed_bytes, cfg);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var cfg: Config = .{};
    var port_set = false;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next(); // argv[0]

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        }
        if (parseBoolFlag(arg, "quiet")) {
            cfg.quiet = true;
            continue;
        }
        if (parseBoolFlag(arg, "full-request")) {
            cfg.minimal_request = false;
            continue;
        }

        if (scripts.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "mode")) {
                cfg.mode = try parseMode(kv.val);
            } else if (std.mem.eql(u8, kv.key, "host")) {
                cfg.host = try a.dupe(u8, kv.val);
            } else if (std.mem.eql(u8, kv.key, "path")) {
                cfg.path = try a.dupe(u8, kv.val);
            } else if (std.mem.eql(u8, kv.key, "port")) {
                cfg.port = try std.fmt.parseInt(u16, kv.val, 10);
                port_set = true;
            } else if (std.mem.eql(u8, kv.key, "conns")) {
                cfg.conns = try std.fmt.parseInt(usize, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "iters")) {
                cfg.iters = try std.fmt.parseInt(u64, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "warmup")) {
                cfg.warmup = try std.fmt.parseInt(u64, kv.val, 10);
            } else if (std.mem.eql(u8, kv.key, "fixed-bytes")) {
                cfg.fixed_bytes = try std.fmt.parseInt(usize, kv.val, 10);
            } else {
                return error.UnknownArg;
            }
            continue;
        }

        return error.UnknownArg;
    }

    if (cfg.conns == 0) return error.BadConns;
    if (cfg.iters == 0) return error.BadIters;
    if (!port_set) {
        if (cfg.mode == .external) cfg.port = 8080 else cfg.port = 0;
    }
    if (cfg.mode == .external and cfg.port == 0) return error.BadPort;

    if (!cfg.quiet and cfg.mode == .zhttp) {
        var buffer: [128]u8 = undefined;
        const stdout_file = std.Io.File.stdout();
        var stdout = stdout_file.writer(init.io, &buffer);
        try stdout.interface.writeAll("== zhttp ==\n");
    }

    switch (cfg.mode) {
        .zhttp => try runZhttp(init, cfg),
        .external => try runExternal(init, cfg),
    }
}
