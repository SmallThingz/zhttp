const std = @import("std");

pub const BenchConfig = struct {
    port: u16,
    conns: usize,
    iters: usize,
    warmup: usize,
    full_request: bool,
};

fn printLabel(io: std.Io, label: []const u8) void {
    var buffer: [256]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &buffer);
    stdout.interface.writeAll(label) catch {};
    stdout.interface.writeAll("\n") catch {};
}

pub fn envInt(env: *const std.process.Environ.Map, name: []const u8, default: usize) usize {
    const v = env.get(name) orelse return default;
    return std.fmt.parseInt(usize, v, 10) catch default;
}

pub fn envBool(env: *const std.process.Environ.Map, name: []const u8, default: bool) bool {
    const v = env.get(name) orelse return default;
    if (std.mem.eql(u8, v, "0")) return false;
    return true;
}

pub fn envString(env: *const std.process.Environ.Map, name: []const u8, default: []const u8) []const u8 {
    return env.get(name) orelse default;
}

pub fn runChecked(io: std.Io, argv: []const []const u8, cwd: ?[]const u8, inherit: bool) !void {
    return runCheckedEnv(io, argv, cwd, inherit, null);
}

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

pub fn runZhttpExternal(io: std.Io, allocator: std.mem.Allocator, cfg: BenchConfig, root: []const u8) !void {
    printLabel(io, "== zhttp ==");
    try runChecked(io, &.{ "zig", "build", "-Doptimize=ReleaseFast" }, root, true);

    var port_buf: [16]u8 = undefined;
    const port_arg = try std.fmt.bufPrint(&port_buf, "--port={d}", .{cfg.port});

    var server = try spawnBackground(
        io,
        &.{ "./zig-out/bin/zhttp-bench-server", port_arg },
        root,
        false,
    );
    defer {
        server.kill(io);
    }

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);

    var conns_buf: [32]u8 = undefined;
    var iters_buf: [32]u8 = undefined;
    var warmup_buf: [32]u8 = undefined;
    var port_num_buf: [32]u8 = undefined;
    const conns_arg = try std.fmt.bufPrint(&conns_buf, "--conns={d}", .{cfg.conns});
    const iters_arg = try std.fmt.bufPrint(&iters_buf, "--iters={d}", .{cfg.iters});
    const warmup_arg = try std.fmt.bufPrint(&warmup_buf, "--warmup={d}", .{cfg.warmup});
    const port_num_arg = try std.fmt.bufPrint(&port_num_buf, "--port={d}", .{cfg.port});

    var bench_args: std.ArrayList([]const u8) = .empty;
    defer bench_args.deinit(allocator);
    try runChecked(io, &.{ "zig", "build", "-Doptimize=ReleaseFast" }, root, true);
    try bench_args.appendSlice(allocator, &.{
        "./zig-out/bin/zhttp-bench",
        "--mode=external",
        "--host=127.0.0.1",
        port_num_arg,
        "--path=/plaintext",
        conns_arg,
        iters_arg,
        warmup_arg,
    });
    if (cfg.full_request) try bench_args.append(allocator, "--full-request");
    try runChecked(io, bench_args.items, root, true);
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
    try writeFile(io, path, out.items);
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
    try writeFile(io, path, out.items);
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
    try writeFile(io, path, out.items);
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
        try writeFile(io, net_path, out.items);
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

        try writeFile(io, epoll_path, final.items);
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
        try writeFile(io, http_date_path, out.items);
    }
}

fn patchFafExampleCargoToml(io: std.Io, allocator: std.mem.Allocator, path: []const u8, core_dir: []const u8) !void {
    const data = try readFileMaybe(io, allocator, path) orelse return;
    const needle = "faf = { git = \"https://github.com/errantmind/faf.git\" }";
    if (std.mem.indexOf(u8, data, needle) == null) return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), needle)) {
            try out.appendSlice(allocator, "faf = { path = \"");
            try out.appendSlice(allocator, core_dir);
            try out.appendSlice(allocator, "\" }");
        } else {
            try out.appendSlice(allocator, line);
        }
        try out.append(allocator, '\n');
    }
    try writeFile(io, path, out.items);
}

fn patchFafExampleMain(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const default_main =
        \\#![allow(clippy::missing_safety_doc, unused_imports, dead_code)]
        \\
        \\#[inline(always)]
        \\fn likely(b: bool) -> bool { b }
        \\use faf::const_concat_bytes;
        \\use faf::const_http::*;
        \\use faf::epoll;
        \\use faf::util::memcmp;
        \\
        \\const ROUTE_PLAINTEXT: &[u8] = b"/plaintext";
        \\const ROUTE_PLAINTEXT_LEN: usize = ROUTE_PLAINTEXT.len();
        \\
        \\const TEXT_PLAIN_CONTENT_TYPE: &[u8] = b"Content-Type: text/plain";
        \\const CONTENT_LENGTH: &[u8] = b"Content-Length: ";
        \\const PLAINTEXT_BODY: &[u8] = b"Hello, World!";
        \\const PLAINTEXT_BODY_LEN: usize = PLAINTEXT_BODY.len();
        \\const PLAINTEXT_BODY_SIZE: &[u8] = b"13";
        \\
        \\const PLAINTEXT_BASE: &[u8] = const_concat_bytes!(
        \\   HTTP_200_OK,
        \\   CRLF,
        \\   SERVER,
        \\   CRLF,
        \\   TEXT_PLAIN_CONTENT_TYPE,
        \\   CRLF,
        \\   CONTENT_LENGTH,
        \\   PLAINTEXT_BODY_SIZE,
        \\   CRLF
        \\);
        \\
        \\const PLAINTEXT_BASE_LEN: usize = PLAINTEXT_BASE.len();
        \\
        \\#[inline(always)]
        \\fn cb(
        \\   method: *const u8,
        \\   method_len: usize,
        \\   path: *const u8,
        \\   path_len: usize,
        \\   response_buffer: *mut u8,
        \\   date_buff: *const u8,
        \\) -> usize {
        \\   unsafe {
        \\      if likely(method_len == GET_LEN && path_len == ROUTE_PLAINTEXT_LEN) {
        \\         if likely(memcmp(GET.as_ptr(), method, GET_LEN) == 0) {
        \\            if likely(memcmp(ROUTE_PLAINTEXT.as_ptr(), path, ROUTE_PLAINTEXT_LEN) == 0) {
        \\               core::ptr::copy_nonoverlapping(PLAINTEXT_BASE.as_ptr(), response_buffer, PLAINTEXT_BASE_LEN);
        \\               core::ptr::copy_nonoverlapping(date_buff, response_buffer.add(PLAINTEXT_BASE_LEN), DATE_LEN);
        \\               core::ptr::copy_nonoverlapping(
        \\                  CRLFCRLF.as_ptr(),
        \\                  response_buffer.add(PLAINTEXT_BASE_LEN + DATE_LEN),
        \\                  CRLFCRLF_LEN,
        \\               );
        \\               core::ptr::copy_nonoverlapping(
        \\                  PLAINTEXT_BODY.as_ptr(),
        \\                  response_buffer.add(PLAINTEXT_BASE_LEN + DATE_LEN + CRLFCRLF_LEN),
        \\                  PLAINTEXT_BODY_LEN,
        \\               );
        \\
        \\               PLAINTEXT_BASE_LEN + DATE_LEN + CRLFCRLF_LEN + PLAINTEXT_BODY_LEN
        \\            } else {
        \\               core::ptr::copy_nonoverlapping(HTTP_404_NOTFOUND.as_ptr(), response_buffer, HTTP_404_NOTFOUND_LEN);
        \\               HTTP_404_NOTFOUND_LEN
        \\            }
        \\         } else {
        \\            core::ptr::copy_nonoverlapping(HTTP_405_NOTALLOWED.as_ptr(), response_buffer, HTTP_405_NOTALLOWED_LEN);
        \\            HTTP_405_NOTALLOWED_LEN
        \\         }
        \\      } else {
        \\         0
        \\      }
        \\   }
        \\}
        \\
        \\#[inline(always)]
        \\pub fn main() {
        \\   epoll::go(8080, cb);
        \\}
        \\
    ;

    const data = try readFileMaybe(io, allocator, path);
    if (data == null or data.?.len == 0) {
        try writeFile(io, path, default_main);
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, data.?, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "#![feature(")) continue;
        if (std.mem.indexOf(u8, line, "use core::intrinsics::likely;") != null or
            std.mem.indexOf(u8, line, "use std::hint::likely;") != null)
        {
            try out.appendSlice(allocator, "#[inline(always)] fn likely(b: bool) -> bool { b }");
            try out.append(allocator, '\n');
            continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    if (std.mem.indexOf(u8, out.items, "fn main") == null) {
        try writeFile(io, path, default_main);
        return;
    }
    try writeFile(io, path, out.items);
}

pub fn runFaf(
    io: std.Io,
    allocator: std.mem.Allocator,
    cfg: BenchConfig,
    faf_dir: []const u8,
    faf_core_dir: []const u8,
    rustc_bin: []const u8,
    environ: std.process.Environ,
    root: []const u8,
) !void {
    printLabel(io, "== FaF ==");
    if (cfg.port != 8080) return error.InvalidPort;

    if (!try hasGitDir(io, allocator, faf_dir)) {
        try runChecked(io, &.{ "git", "clone", "https://github.com/errantmind/faf-example", faf_dir }, null, true);
    }

    const lock_path = try std.fs.path.join(allocator, &.{ faf_dir, "Cargo.lock" });
    defer allocator.free(lock_path);
    const rev_file = try std.fs.path.join(allocator, &.{ faf_dir, ".faf_rev" });
    defer allocator.free(rev_file);
    const main_path = try std.fs.path.join(allocator, &.{ faf_dir, "src", "main.rs" });
    defer allocator.free(main_path);
    const cargo_path = try std.fs.path.join(allocator, &.{ faf_dir, "Cargo.toml" });
    defer allocator.free(cargo_path);

    var faf_rev = try detectFafRevFromLock(io, allocator, lock_path);
    if (faf_rev == null) faf_rev = try detectFafRevFromFile(io, allocator, rev_file);
    if (faf_rev == null and dirExists(io, faf_core_dir)) faf_rev = try gitRevParse(io, allocator, faf_core_dir);
    if (faf_rev == null) return error.MissingFafRevision;

    try writeFile(io, rev_file, faf_rev.?);

    if (!try hasGitDir(io, allocator, faf_core_dir)) {
        try runChecked(io, &.{ "git", "clone", "https://github.com/errantmind/faf", faf_core_dir }, null, true);
    }

    _ = runChecked(io, &.{ "git", "-C", faf_core_dir, "fetch", "--all", "--tags" }, null, false) catch {};
    try runChecked(io, &.{ "git", "-C", faf_core_dir, "reset", "--hard", "-q" }, null, true);
    try runChecked(io, &.{ "git", "-C", faf_core_dir, "checkout", "-q", faf_rev.? }, null, true);

    const util_path = try std.fs.path.join(allocator, &.{ faf_core_dir, "src", "util.rs" });
    defer allocator.free(util_path);
    const lib_path = try std.fs.path.join(allocator, &.{ faf_core_dir, "src", "lib.rs" });
    defer allocator.free(lib_path);
    const epoll_path = try std.fs.path.join(allocator, &.{ faf_core_dir, "src", "epoll.rs" });
    defer allocator.free(epoll_path);
    const req_path = try std.fs.path.join(allocator, &.{ faf_core_dir, "src", "http_request_path.rs" });
    defer allocator.free(req_path);
    try patchFafUtil(io, allocator, util_path);
    try patchFafLib(io, allocator, lib_path);
    try patchFafHints(io, allocator, epoll_path);
    try patchFafHints(io, allocator, req_path);
    try patchFafWarnings(io, allocator, faf_core_dir);

    try patchFafExampleCargoToml(io, allocator, cargo_path, faf_core_dir);
    try patchFafExampleMain(io, allocator, main_path);

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
    {
        var child = std.process.spawn(io, .{
            .argv = &.{ "cargo", "build", "--release" },
            .cwd = .{ .path = faf_dir },
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
        &.{ "./target/release/faf-ex" },
        faf_dir,
        false,
    );
    defer {
        server.kill(io);
    }

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);

    var conns_buf: [32]u8 = undefined;
    var iters_buf: [32]u8 = undefined;
    var warmup_buf: [32]u8 = undefined;
    const conns_arg = try std.fmt.bufPrint(&conns_buf, "--conns={d}", .{cfg.conns});
    const iters_arg = try std.fmt.bufPrint(&iters_buf, "--iters={d}", .{cfg.iters});
    const warmup_arg = try std.fmt.bufPrint(&warmup_buf, "--warmup={d}", .{cfg.warmup});

    try runChecked(io, &.{ "zig", "build", "-Doptimize=ReleaseFast" }, root, true);

    var bench_args: std.ArrayList([]const u8) = .empty;
    defer bench_args.deinit(allocator);
    try bench_args.appendSlice(allocator, &.{
        "./zig-out/bin/zhttp-bench",
        "--mode=external",
        "--host=127.0.0.1",
        "--port=8080",
        "--path=/plaintext",
        conns_arg,
        iters_arg,
        warmup_arg,
    });
    if (cfg.full_request) try bench_args.append(allocator, "--full-request");
    try env.put("BENCH_LABEL", "faf ");
    try runCheckedEnv(io, bench_args.items, root, true, &env);
}
