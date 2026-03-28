const std = @import("std");
const builtin = @import("builtin");

pub const BenchConfig = struct {
    /// Stores `port`.
    port: u16,
    /// Stores `host`.
    host: []const u8 = "127.0.0.1",
    /// Stores `path`.
    path: []const u8 = "/plaintext",
    /// Stores `conns`.
    conns: usize,
    /// Stores `iters`.
    iters: usize,
    /// Stores `warmup`.
    warmup: usize,
    /// Stores `full_request`.
    full_request: bool,
    /// Stores `fixed_bytes`.
    fixed_bytes: ?usize = null,
    /// Stores `quiet`.
    quiet: bool = false,
};

/// Implements trim cr.
pub fn trimCR(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn trimLeftSpaceTab(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        const a = haystack[i];
        const b = needle[i];
        const al = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const bl = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (al != bl) return false;
    }
    return true;
}

fn setTcpNoDelay(stream: *const std.Io.net.Stream) void {
    if (builtin.os.tag != .windows) {
        const fd = stream.socket.handle;
        const one: c_int = 1;
        _ = std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
    }
}

fn buildRequest(a: std.mem.Allocator, host: []const u8, path: []const u8, full: bool) ![]const u8 {
    if (!full) {
        return std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\n\r\n", .{path});
    }
    return std.fmt.allocPrint(
        a,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n",
        .{ path, host },
    );
}

fn discoverFixedResponseBytes(io: std.Io, address: std.Io.net.IpAddress, request_bytes: []const u8) !usize {
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
        const line = trimCR(line0);
        if (line.len == 0) break;

        if (asciiStartsWithIgnoreCase(line, "content-length:")) {
            var v = line["content-length:".len..];
            v = trimLeftSpaceTab(v);
            content_length = try std.fmt.parseInt(usize, v, 10);
        }
    }

    const body_len = content_length orelse return error.MissingContentLength;
    var remaining = body_len;
    while (remaining != 0) {
        const got = try sr.interface.discard(.limited(remaining));
        if (got == 0) return error.EndOfStream;
        remaining -= got;
    }
    return header_bytes + body_len;
}

fn printLabel(io: std.Io, label: []const u8) void {
    var buffer: [256]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &buffer);
    stdout.interface.writeAll(label) catch {};
    stdout.interface.writeAll("\n") catch {};
}

/// Implements env int.
pub fn envInt(env: *const std.process.Environ.Map, name: []const u8, default: usize) usize {
    const v = env.get(name) orelse return default;
    return std.fmt.parseInt(usize, v, 10) catch default;
}

/// Implements env bool.
pub fn envBool(env: *const std.process.Environ.Map, name: []const u8, default: bool) bool {
    const v = env.get(name) orelse return default;
    if (std.mem.eql(u8, v, "0")) return false;
    return true;
}

/// Implements env string.
pub fn envString(env: *const std.process.Environ.Map, name: []const u8, default: []const u8) []const u8 {
    return env.get(name) orelse default;
}

/// Implements parse key val.
pub fn parseKeyVal(arg: []const u8) ?struct { key: []const u8, val: []const u8 } {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    return .{ .key = arg[2..eq], .val = arg[eq + 1 ..] };
}

/// Implements run checked.
pub fn runChecked(io: std.Io, argv: []const []const u8, cwd: ?[]const u8, inherit: bool) !void {
    return runCheckedEnv(io, argv, cwd, inherit, null);
}

/// Implements run checked env.
pub fn runCheckedEnv(
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
    inherit: bool,
    env_map: ?*const std.process.Environ.Map,
) !void {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |p| .{ .path = p } else .inherit;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .environ_map = env_map,
        .stdin = .ignore,
        .stdout = if (inherit) .inherit else .ignore,
        .stderr = if (inherit) .inherit else .ignore,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ProcessFailed,
        else => return error.ProcessFailed,
    }
}

/// Implements spawn background.
pub fn spawnBackground(io: std.Io, argv: []const []const u8, cwd: ?[]const u8, inherit: bool) !std.process.Child {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |p| .{ .path = p } else .inherit;
    return try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .stdin = .ignore,
        .stdout = if (inherit) .inherit else .ignore,
        .stderr = if (inherit) .inherit else .ignore,
    });
}

fn buildZigExe(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    src_rel: []const u8,
    out_rel: []const u8,
    name: []const u8,
) !void {
    const src = try std.fs.path.join(allocator, &.{ root, src_rel });
    defer allocator.free(src);
    const zhttp = try std.fs.path.join(allocator, &.{ root, "src", "root.zig" });
    defer allocator.free(zhttp);
    const out = try std.fs.path.join(allocator, &.{ root, out_rel });
    defer allocator.free(out);
    const out_dir = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin" });
    defer allocator.free(out_dir);
    const cache_dir = try std.fs.path.join(allocator, &.{ root, ".zig-cache" });
    defer allocator.free(cache_dir);
    const global_cache_dir = try std.fs.path.join(allocator, &.{ root, ".zig-cache-global" });
    defer allocator.free(global_cache_dir);

    const out_stat = blk: {
        if (std.Io.Dir.openFileAbsolute(io, out, .{})) |file| {
            defer file.close(io);
            break :blk file.stat(io) catch null;
        } else |_| break :blk null;
    };
    if (out_stat) |ost| {
        const src_stat = blk: {
            const file = try std.Io.Dir.openFileAbsolute(io, src, .{});
            defer file.close(io);
            break :blk try file.stat(io);
        };
        const zhttp_stat = blk: {
            const file = try std.Io.Dir.openFileAbsolute(io, zhttp, .{});
            defer file.close(io);
            break :blk try file.stat(io);
        };
        if (src_stat.mtime.nanoseconds <= ost.mtime.nanoseconds and
            zhttp_stat.mtime.nanoseconds <= ost.mtime.nanoseconds)
        {
            return;
        }
    }

    const mroot = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{src});
    defer allocator.free(mroot);
    const mzhttp = try std.fmt.allocPrint(allocator, "-Mzhttp={s}", .{zhttp});
    defer allocator.free(mzhttp);
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{out});
    defer allocator.free(emit_arg);
    try std.Io.Dir.createDirPath(.cwd(), io, out_dir);

    try runChecked(io, &.{
        "zig",
        "build-exe",
        "-OReleaseFast",
        "--dep",
        "zhttp",
        mroot,
        mzhttp,
        "--name",
        name,
        emit_arg,
        "--cache-dir",
        cache_dir,
        "--global-cache-dir",
        global_cache_dir,
    }, root, true);
}

fn terminateChild(io: std.Io, child: *std.process.Child) void {
    if (child.id == null) return;
    if (builtin.os.tag == .windows) {
        child.kill(io);
        return;
    }
    if (child.id) |pid| {
        std.posix.kill(pid, .KILL) catch {};
    }
    _ = child.wait(io) catch {};
}

/// Implements run zhttp external.
pub fn runZhttpExternal(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: BenchConfig,
    root: []const u8,
    environ: std.process.Environ,
) !void {
    printLabel(io, "== zhttp ==");
    try buildZigExe(io, allocator, root, "benchmark/zhttp_server.zig", "zig-out/bin/zhttp-bench-server", "zhttp-bench-server");

    var port_buf: [16]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "--port={d}", .{cfg.port});

    var server = try spawnBackground(
        io,
        &.{ "./zig-out/bin/zhttp-bench-server", port_arg },
        root,
        false,
    );
    defer terminateChild(io, &server);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);

    var conns_buf: [32]u8 = undefined;
    var iters_buf: [32]u8 = undefined;
    var warmup_buf: [32]u8 = undefined;
    var port_num_buf: [32]u8 = undefined;
    const conns_arg = try std.fmt.bufPrint(&conns_buf, "--conns={d}", .{cfg.conns});
    const iters_arg = try std.fmt.bufPrint(&iters_buf, "--iters={d}", .{cfg.iters});
    const warmup_arg = try std.fmt.bufPrint(&warmup_buf, "--warmup={d}", .{cfg.warmup});
    const port_num_arg = try std.fmt.bufPrint(&port_num_buf, "--port={d}", .{cfg.port});
    var host_buf: [64]u8 = undefined;
    const host_arg = try std.fmt.bufPrint(&host_buf, "--host={s}", .{cfg.host});
    var path_buf: [256]u8 = undefined;
    const path_arg = try std.fmt.bufPrint(&path_buf, "--path={s}", .{cfg.path});

    var bench_args: std.ArrayList([]const u8) = .empty;
    defer bench_args.deinit(allocator);
    try buildZigExe(io, allocator, root, "benchmark/bench.zig", "zig-out/bin/zhttp-bench", "zhttp-bench");
    try bench_args.appendSlice(allocator, &.{
        "./zig-out/bin/zhttp-bench",
        "--mode=external",
        host_arg,
        port_num_arg,
        path_arg,
        conns_arg,
        iters_arg,
        warmup_arg,
    });
    if (cfg.full_request) try bench_args.append(allocator, "--full-request");
    if (cfg.quiet) try bench_args.append(allocator, "--quiet");
    if (cfg.fixed_bytes) |v| {
        var fixed_buf: [32]u8 = undefined;
        const fixed_arg = try std.fmt.bufPrint(&fixed_buf, "--fixed-bytes={d}", .{v});
        try bench_args.append(allocator, fixed_arg);
    }
    var env = try std.process.Environ.createMap(environ, allocator);
    defer env.deinit();
    try env.put("BENCH_LABEL", "zhttp ");
    try runCheckedEnv(io, bench_args.items, root, true, &env);
}

fn dirExists(io: std.Io, path: []const u8) bool {
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn hasGitDir(io: std.Io, allocator: std.mem.Allocator, dir: []const u8) !bool {
    const git_path = try std.fs.path.join(allocator, &.{ dir, ".git" });
    defer allocator.free(git_path);
    return dirExists(io, git_path);
}

fn absPath(allocator: std.mem.Allocator, root: []const u8, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    return try std.fs.path.join(allocator, &.{ root, path });
}

fn markerMatches(io: std.Io, allocator: std.mem.Allocator, path: []const u8, rev: []const u8) bool {
    const data = readFileMaybe(io, allocator, path) catch return false;
    if (data == null) return false;
    defer allocator.free(data.?);
    const trimmed = std.mem.trim(u8, data.?, " \t\r\n");
    return std.mem.eql(u8, trimmed, rev);
}

fn readFileMaybe(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > std.math.maxInt(usize)) return error.FileTooLarge;
    const len: usize = @intCast(stat.size);

    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.interface.readSliceAll(out);
    return out;
}

fn detectFafRevFromLock(io: std.Io, allocator: std.mem.Allocator, lock_path: []const u8) !?[]u8 {
    const data = try readFileMaybe(io, allocator, lock_path);
    if (data == null) return null;
    const buf = data.?;
    const needle = "git+https://github.com/errantmind/faf.git#";
    const idx = std.mem.indexOf(u8, buf, needle) orelse return null;
    const start = idx + needle.len;
    var end = start;
    while (end < buf.len and buf[end] != '\n' and buf[end] != '"' and buf[end] != '\r') : (end += 1) {}
    if (end <= start) return null;
    return try allocator.dupe(u8, std.mem.trim(u8, buf[start..end], " \t"));
}

fn detectFafRevFromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const data = try readFileMaybe(io, allocator, path);
    if (data == null) return null;
    const trimmed = std.mem.trim(u8, data.?, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn gitRevParse(io: std.Io, allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
    const res = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", dir, "rev-parse", "HEAD" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return null;
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn writeFileIfChanged(io: std.Io, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !bool {
    const old = try readFileMaybe(io, allocator, path);
    if (old) |buf| {
        defer allocator.free(buf);
        if (std.mem.eql(u8, buf, data)) return false;
    }
    try writeFile(io, path, data);
    return true;
}

fn patchFafUtil(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const data = try readFileMaybe(io, allocator, path) orelse return;
    if (std.mem.indexOf(u8, data, "prefetch_read_data") == null) return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "core::intrinsics::prefetch_read_data") != null) {
            try out.appendSlice(allocator, "   let _ = (p, offset);");
            try out.append(allocator, '\n');
            continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    _ = try writeFileIfChanged(io, allocator, path, out.items);
}

fn patchFafLib(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const data = try readFileMaybe(io, allocator, path) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "#![feature(")) continue;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    _ = try writeFileIfChanged(io, allocator, path, out.items);
}

fn patchFafHints(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const data = try readFileMaybe(io, allocator, path) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "use core::intrinsics::{likely, unlikely};") != null or
            std.mem.indexOf(u8, line, "use std::hint::{likely, unlikely};") != null)
        {
            try out.appendSlice(allocator, "#[inline(always)] fn likely(b: bool) -> bool { b }");
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, "#[inline(always)] fn unlikely(b: bool) -> bool { b }");
            try out.append(allocator, '\n');
            continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    _ = try writeFileIfChanged(io, allocator, path, out.items);
}

fn patchFafWarnings(io: std.Io, allocator: std.mem.Allocator, faf_core_dir: []const u8) !void {
    const net_path = try std.fs.path.join(allocator, &.{ faf_core_dir, "src", "net.rs" });
    defer allocator.free(net_path);
    const epoll_path = try std.fs.path.join(allocator, &.{ faf_core_dir, "src", "epoll.rs" });
    defer allocator.free(epoll_path);
    const http_date_path = try std.fs.path.join(allocator, &.{ faf_core_dir, "src", "http_date.rs" });
    defer allocator.free(http_date_path);

    if (readFileMaybe(io, allocator, net_path) catch null) |data| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const needle = "let ret = sys_call!(";
            if (std.mem.indexOf(u8, line, needle)) |idx| {
                try out.appendSlice(allocator, line[0..idx]);
                try out.appendSlice(allocator, "let _ret = sys_call!(");
                try out.appendSlice(allocator, line[idx + needle.len ..]);
            } else {
                try out.appendSlice(allocator, line);
            }
            try out.append(allocator, '\n');
        }
        _ = try writeFileIfChanged(io, allocator, net_path, out.items);
    }

    if (readFileMaybe(io, allocator, epoll_path) catch null) |data| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "http_date::get_http_date(unsafe { &mut *(&raw mut HTTP_DATE.0) });") != null) {
                try out.appendSlice(allocator, "      http_date::get_http_date(&mut *(&raw mut HTTP_DATE.0));");
                try out.append(allocator, '\n');
                continue;
            }
            var cursor: usize = 0;
            const pat1 = "&mut HTTP_DATE.0";
            const rep1 = "unsafe { &mut *(&raw mut HTTP_DATE.0) }";
            const pat2 = "HTTP_DATE.0.as_ptr()";
            const rep2 = "(&raw const HTTP_DATE.0) as *const u8";
            const pat3 = "unsafe { &mut *(&raw mut HTTP_DATE.0) }";
            const rep3 = "&mut *(&raw mut HTTP_DATE.0)";

            while (cursor < line.len) {
                const idx1 = std.mem.indexOfPos(u8, line, cursor, pat1);
                const idx2 = std.mem.indexOfPos(u8, line, cursor, pat2);
                const idx3 = std.mem.indexOfPos(u8, line, cursor, pat3);
                if (idx1 == null and idx2 == null and idx3 == null) {
                    try out.appendSlice(allocator, line[cursor..]);
                    break;
                }
                var idx = idx1;
                var which: u8 = 1;
                if (idx2 != null and (idx == null or idx2.? < idx.?)) {
                    idx = idx2;
                    which = 2;
                }
                if (idx3 != null and (idx == null or idx3.? < idx.?)) {
                    idx = idx3;
                    which = 3;
                }
                const at = idx.?;
                try out.appendSlice(allocator, line[cursor..at]);
                if (which == 1) {
                    try out.appendSlice(allocator, rep1);
                    cursor = at + pat1.len;
                } else if (which == 2) {
                    try out.appendSlice(allocator, rep2);
                    cursor = at + pat2.len;
                } else {
                    try out.appendSlice(allocator, rep3);
                    cursor = at + pat3.len;
                }
            }
            try out.append(allocator, '\n');
        }
        // Second pass: drop redundant unsafe blocks around get_http_date.
        var lines2: std.ArrayList([]const u8) = .empty;
        defer lines2.deinit(allocator);
        var it2 = std.mem.splitScalar(u8, out.items, '\n');
        while (it2.next()) |l| {
            try lines2.append(allocator, l);
        }

        var final: std.ArrayList(u8) = .empty;
        defer final.deinit(allocator);
        var i: usize = 0;
        while (i < lines2.items.len) : (i += 1) {
            const trimmed = std.mem.trim(u8, lines2.items[i], " \t");
            if (std.mem.eql(u8, trimmed, "unsafe {") and i + 2 < lines2.items.len) {
                const ln = std.mem.trim(u8, lines2.items[i + 1], " \t");
                const le = std.mem.trim(u8, lines2.items[i + 2], " \t");
                if (std.mem.startsWith(u8, ln, "http_date::get_http_date(") and std.mem.eql(u8, le, "}")) {
                    try final.appendSlice(allocator, lines2.items[i + 1]);
                    try final.append(allocator, '\n');
                    i += 2;
                    continue;
                }
            }
            try final.appendSlice(allocator, lines2.items[i]);
            try final.append(allocator, '\n');
        }

        _ = try writeFileIfChanged(io, allocator, epoll_path, final.items);
    }

    if (readFileMaybe(io, allocator, http_date_path) catch null) |data| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var it = std.mem.splitScalar(u8, data, '\n');
        const pat = "MaybeUninit::uninit().assume_init()";
        const rep = "MaybeUninit::zeroed().assume_init()";
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, pat)) |idx| {
                try out.appendSlice(allocator, line[0..idx]);
                try out.appendSlice(allocator, rep);
                try out.appendSlice(allocator, line[idx + pat.len ..]);
            } else {
                try out.appendSlice(allocator, line);
            }
            try out.append(allocator, '\n');
        }
        _ = try writeFileIfChanged(io, allocator, http_date_path, out.items);
    }
}

fn patchFafExampleCargoToml(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    core_dir: []const u8,
    lock_path: []const u8,
) !void {
    const data = try readFileMaybe(io, allocator, path) orelse return;
    const needle = "faf = { git = \"https://github.com/errantmind/faf.git\"";
    if (std.mem.indexOf(u8, data, needle) == null) return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, data, '\n');
    var changed = false;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) {
            try out.appendSlice(allocator, "faf = { path = \"");
            try out.appendSlice(allocator, core_dir);
            try out.appendSlice(allocator, "\" }");
            changed = true;
        } else {
            try out.appendSlice(allocator, line);
        }
        try out.append(allocator, '\n');
    }
    if (changed) {
        _ = try writeFileIfChanged(io, allocator, path, out.items);
        std.Io.Dir.deleteFileAbsolute(io, lock_path) catch {};
    }
}

fn patchFafExampleMain(io: std.Io, allocator: std.mem.Allocator, root: []const u8, path: []const u8) !void {
    const src = try std.fs.path.join(allocator, &.{ root, "benchmark", "faf_example_main.rs" });
    defer allocator.free(src);
    const default_main = try readFileMaybe(io, allocator, src) orelse return error.FileNotFound;
    defer allocator.free(default_main);
    _ = try writeFileIfChanged(io, allocator, path, default_main);
}

/// Implements run faf.
pub fn runFaf(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: BenchConfig,
    faf_dir: []const u8,
    faf_core_dir: []const u8,
    rustc_bin: []const u8,
    bench_bin_opt: ?[]const u8,
    environ: std.process.Environ,
    root: []const u8,
) !void {
    printLabel(io, "== FaF ==");
    if (cfg.port != 8080) return error.InvalidPort;

    const faf_dir_abs = try absPath(allocator, root, faf_dir);
    defer allocator.free(faf_dir_abs);
    const faf_core_dir_abs = try absPath(allocator, root, faf_core_dir);
    defer allocator.free(faf_core_dir_abs);

    if (!try hasGitDir(io, allocator, faf_dir_abs)) {
        try runChecked(io, &.{ "git", "clone", "https://github.com/errantmind/faf-example", faf_dir_abs }, null, true);
    }

    const lock_path = try std.fs.path.join(allocator, &.{ faf_dir_abs, "Cargo.lock" });
    defer allocator.free(lock_path);
    const rev_file = try std.fs.path.join(allocator, &.{ faf_dir_abs, ".faf_rev" });
    defer allocator.free(rev_file);
    const main_path = try std.fs.path.join(allocator, &.{ faf_dir_abs, "src", "main.rs" });
    defer allocator.free(main_path);
    const cargo_path = try std.fs.path.join(allocator, &.{ faf_dir_abs, "Cargo.toml" });
    defer allocator.free(cargo_path);

    var faf_rev = try detectFafRevFromLock(io, allocator, lock_path);
    if (faf_rev == null) faf_rev = try detectFafRevFromFile(io, allocator, rev_file);

    if (faf_rev == null) {
        if (!try hasGitDir(io, allocator, faf_core_dir_abs)) {
            try runChecked(io, &.{ "git", "clone", "https://github.com/errantmind/faf", faf_core_dir_abs }, null, true);
        }
        faf_rev = try gitRevParse(io, allocator, faf_core_dir_abs);
    }

    if (faf_rev == null) return error.MissingFafRevision;

    try writeFile(io, rev_file, faf_rev.?);

    if (!try hasGitDir(io, allocator, faf_core_dir_abs)) {
        try runChecked(io, &.{ "git", "clone", "https://github.com/errantmind/faf", faf_core_dir_abs }, null, true);
    }

    const core_marker = try std.fs.path.join(allocator, &.{ faf_core_dir_abs, ".zhttp_patch_rev" });
    defer allocator.free(core_marker);
    const core_patched = markerMatches(io, allocator, core_marker, faf_rev.?);

    if (!core_patched) {
        _ = runChecked(io, &.{ "git", "-C", faf_core_dir_abs, "fetch", "--all", "--tags" }, null, false) catch {};
        try runChecked(io, &.{ "git", "-C", faf_core_dir_abs, "reset", "--hard", "-q" }, null, true);
        try runChecked(io, &.{ "git", "-C", faf_core_dir_abs, "checkout", "-q", faf_rev.? }, null, true);
    }

    const util_path = try std.fs.path.join(allocator, &.{ faf_core_dir_abs, "src", "util.rs" });
    defer allocator.free(util_path);
    const lib_path = try std.fs.path.join(allocator, &.{ faf_core_dir_abs, "src", "lib.rs" });
    defer allocator.free(lib_path);
    const epoll_path = try std.fs.path.join(allocator, &.{ faf_core_dir_abs, "src", "epoll.rs" });
    defer allocator.free(epoll_path);
    const req_path = try std.fs.path.join(allocator, &.{ faf_core_dir_abs, "src", "http_request_path.rs" });
    defer allocator.free(req_path);
    if (!core_patched) {
        try patchFafUtil(io, allocator, util_path);
        try patchFafLib(io, allocator, lib_path);
        try patchFafHints(io, allocator, epoll_path);
        try patchFafHints(io, allocator, req_path);
        try patchFafWarnings(io, allocator, faf_core_dir_abs);
        _ = try writeFileIfChanged(io, allocator, core_marker, faf_rev.?);
    }

    const ex_marker = try std.fs.path.join(allocator, &.{ faf_dir_abs, ".zhttp_patch_rev" });
    defer allocator.free(ex_marker);
    var ex_patched = markerMatches(io, allocator, ex_marker, faf_rev.?);
    if (ex_patched) {
        const cargo_data = try readFileMaybe(io, allocator, cargo_path);
        if (cargo_data == null or std.mem.indexOf(u8, cargo_data.?, faf_core_dir_abs) == null) {
            ex_patched = false;
        }
        if (cargo_data) |buf| allocator.free(buf);
    }
    if (ex_patched) {
        const main_data = try readFileMaybe(io, allocator, main_path);
        if (main_data == null) {
            ex_patched = false;
        } else {
            const tmpl_path = try std.fs.path.join(allocator, &.{ root, "benchmark", "faf_example_main.rs" });
            defer allocator.free(tmpl_path);
            const tmpl_data = try readFileMaybe(io, allocator, tmpl_path) orelse return error.FileNotFound;
            defer allocator.free(tmpl_data);
            if (!std.mem.eql(u8, main_data.?, tmpl_data)) {
                ex_patched = false;
            }
            allocator.free(main_data.?);
        }
    }
    if (!ex_patched) {
        try patchFafExampleCargoToml(io, allocator, cargo_path, faf_core_dir_abs, lock_path);
        try patchFafExampleMain(io, allocator, root, main_path);
        _ = try writeFileIfChanged(io, allocator, ex_marker, faf_rev.?);
    }

    var env = try std.process.Environ.createMap(environ, allocator);
    defer env.deinit();
    const rustflags = env.get("RUSTFLAGS") orelse "";
    if (rustflags.len == 0) {
        try env.put("RUSTFLAGS", "-Ctarget-cpu=native");
    }

    var rustc_cmd = rustc_bin;
    if (std.fs.path.isAbsolute(rustc_bin)) {
        if (std.Io.Dir.openFileAbsolute(io, rustc_bin, .{})) |file| {
            file.close(io);
        } else |_| {
            rustc_cmd = "rustc";
        }
    }
    try env.put("RUSTC", rustc_cmd);
    const faf_bin = try std.fs.path.join(allocator, &.{ faf_dir_abs, "target", "release", "faf-ex" });
    defer allocator.free(faf_bin);
    var bin_exists = false;
    if (std.Io.Dir.openFileAbsolute(io, faf_bin, .{})) |file| {
        file.close(io);
        bin_exists = true;
    } else |_| {}

    const need_build = !core_patched or !ex_patched or !bin_exists;
    if (need_build) {
        var child = std.process.spawn(io, .{
            .argv = &.{ "cargo", "build", "--release" },
            .cwd = .{ .path = faf_dir_abs },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.CargoMissing,
            else => return err,
        };
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) return error.ProcessFailed,
            else => return error.ProcessFailed,
        }
    }

    var server = try spawnBackground(
        io,
        &.{"./target/release/faf-ex"},
        faf_dir_abs,
        false,
    );
    defer terminateChild(io, &server);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);
    const addr = try std.Io.net.IpAddress.parseIp4(cfg.host, cfg.port);
    const req_bytes = try buildRequest(allocator, cfg.host, cfg.path, cfg.full_request);
    defer allocator.free(req_bytes);
    const fixed_first = try discoverFixedResponseBytes(io, addr, req_bytes);
    const fixed_second = try discoverFixedResponseBytes(io, addr, req_bytes);
    if (fixed_first != fixed_second) return error.ResponseSizeChanged;

    var conns_buf: [32]u8 = undefined;
    var iters_buf: [32]u8 = undefined;
    var warmup_buf: [32]u8 = undefined;
    var host_buf: [64]u8 = undefined;
    var port_buf: [32]u8 = undefined;
    var path_buf: [256]u8 = undefined;
    const conns_arg = try std.fmt.bufPrint(&conns_buf, "--conns={d}", .{cfg.conns});
    const iters_arg = try std.fmt.bufPrint(&iters_buf, "--iters={d}", .{cfg.iters});
    const warmup_arg = try std.fmt.bufPrint(&warmup_buf, "--warmup={d}", .{cfg.warmup});
    const host_arg = try std.fmt.bufPrint(&host_buf, "--host={s}", .{cfg.host});
    const port_arg = try std.fmt.bufPrint(&port_buf, "--port={d}", .{cfg.port});
    const path_arg = try std.fmt.bufPrint(&path_buf, "--path={s}", .{cfg.path});

    var bench_path: []const u8 = undefined;
    if (bench_bin_opt) |p| {
        bench_path = p;
    } else {
        bench_path = "./zig-out/bin/zhttp-bench";
        const abs_bench = try std.fs.path.join(allocator, &.{ root, "zig-out", "bin", "zhttp-bench" });
        defer allocator.free(abs_bench);
        if (std.Io.Dir.openFileAbsolute(io, abs_bench, .{})) |file| {
            file.close(io);
        } else |_| {
            return error.BenchBinaryMissing;
        }
    }

    var bench_args: std.ArrayList([]const u8) = .empty;
    defer bench_args.deinit(allocator);
    try bench_args.appendSlice(allocator, &.{
        bench_path,
        "--mode=external",
        host_arg,
        port_arg,
        path_arg,
        conns_arg,
        iters_arg,
        warmup_arg,
    });
    if (cfg.full_request) try bench_args.append(allocator, "--full-request");
    if (cfg.quiet) try bench_args.append(allocator, "--quiet");
    const fixed_bytes = cfg.fixed_bytes orelse fixed_first;
    if (cfg.fixed_bytes != null and fixed_bytes != fixed_first) return error.FixedBytesMismatch;
    var fixed_buf: [32]u8 = undefined;
    const fixed_arg = try std.fmt.bufPrint(&fixed_buf, "--fixed-bytes={d}", .{fixed_bytes});
    try bench_args.append(allocator, fixed_arg);
    try env.put("BENCH_LABEL", "faf ");
    try runCheckedEnv(io, bench_args.items, root, true, &env);
}
