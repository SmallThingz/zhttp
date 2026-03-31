const std = @import("std");
const scripts = @import("scripts.zig");

fn writeLine(io: std.Io, text: []const u8) !void {
    var buffer: [512]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &buffer);
    try stdout.interface.writeAll(text);
    try stdout.interface.writeAll("\n");
}

fn printTopRows(io: std.Io, text: []const u8, top_n: usize) !usize {
    var printed: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (!(trimmed[0] >= '0' and trimmed[0] <= '9')) continue;
        try writeLine(io, trimmed);
        printed += 1;
        if (printed >= top_n) break;
    }
    return printed;
}

/// Starts this executable.
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.process.currentPathAlloc(init.io, allocator);
    const env = init.environ_map;

    const perf_data = scripts.envString(env, "PERF_DATA", "perf.zhttp.server.data");
    const perf_top_n = scripts.envInt(env, "PERF_TOP_N", 20);
    const full_report = scripts.envBool(env, "FULL_REPORT", false);
    const perf_tree = scripts.envBool(env, "PERF_TREE", true);
    const perf_percent = scripts.envString(env, "PERF_PERCENT", "1");
    const perf_tree_depth = scripts.envInt(env, "PERF_TREE_DEPTH", 6);
    const flamegraph = scripts.envBool(env, "FLAMEGRAPH", false);
    const flamegraph_out = scripts.envString(env, "FLAMEGRAPH_OUT", "perf.svg");

    const mode = scripts.envString(env, "MODE", "zhttp");
    const path = scripts.envString(env, "PATH_NAME", scripts.envString(env, "BENCH_PATH", "/plaintext"));
    const conns = scripts.envInt(env, "CONNS", 1);
    const iters = scripts.envInt(env, "ITERS", 100000);
    const warmup = scripts.envInt(env, "WARMUP", 10000);
    const quiet = scripts.envBool(env, "QUIET", false);
    const full_request = scripts.envBool(env, "FULL_REQUEST", false);
    const reuse = scripts.envBool(env, "REUSE", true);
    const fixed_bytes = scripts.envOptionalInt(env, "FIXED_BYTES");

    try scripts.ensureBenchBinary(init.io, allocator, root);

    var bench_args: std.ArrayList([]const u8) = .empty;
    defer bench_args.deinit(allocator);
    try bench_args.append(allocator, "./zig-out/bin/zhttp-bench");
    try bench_args.append(allocator, try std.fmt.allocPrint(allocator, "--mode={s}", .{mode}));
    try bench_args.append(allocator, try std.fmt.allocPrint(allocator, "--conns={d}", .{conns}));
    try bench_args.append(allocator, try std.fmt.allocPrint(allocator, "--iters={d}", .{iters}));
    try bench_args.append(allocator, try std.fmt.allocPrint(allocator, "--warmup={d}", .{warmup}));
    try bench_args.append(allocator, try std.fmt.allocPrint(allocator, "--path={s}", .{path}));
    try bench_args.append(allocator, if (reuse) "--reuse=1" else "--reuse=0");
    if (quiet) try bench_args.append(allocator, "--quiet");
    if (full_request) try bench_args.append(allocator, "--full-request");
    if (fixed_bytes) |v| {
        try bench_args.append(allocator, try std.fmt.allocPrint(allocator, "--fixed-bytes={d}", .{v}));
    }

    try writeLine(init.io, "== perf record ==");
    {
        var record_args: std.ArrayList([]const u8) = .empty;
        defer record_args.deinit(allocator);
        try record_args.appendSlice(allocator, &.{ "perf", "record", "-g", "-o", perf_data, "--" });
        try record_args.appendSlice(allocator, bench_args.items);
        try scripts.runChecked(init.io, record_args.items, root, true);
    }

    if (perf_tree) {
        try writeLine(init.io, "== perf report (tree) ==");
        const call_graph = try std.fmt.allocPrint(
            allocator,
            "graph,{s},{d},caller,function,percent",
            .{ perf_percent, perf_tree_depth },
        );
        try scripts.runChecked(init.io, &.{
            "perf",
            "report",
            "--stdio",
            "-i",
            perf_data,
            "--call-graph",
            call_graph,
            "--sort=symbol",
            "--percent-limit",
            perf_percent,
            "--stdio-color=never",
        }, root, true);
    } else {
        try writeLine(init.io, "== perf report (top) ==");
        const result = try std.process.run(allocator, init.io, .{
            .argv = &.{
                "perf",
                "report",
                "--stdio",
                "-i",
                perf_data,
                "--call-graph=graph",
                "--sort=symbol",
                "--percent-limit",
                perf_percent,
                "--no-children",
            },
            .cwd = .{ .path = root },
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(8 * 1024 * 1024),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.ProcessFailed,
            else => return error.ProcessFailed,
        }

        var printed: usize = 0;
        printed += try printTopRows(init.io, result.stdout, perf_top_n);
        if (printed < perf_top_n) {
            printed += try printTopRows(init.io, result.stderr, perf_top_n - printed);
        }
        if (printed == 0) {
            try writeLine(init.io, "perf report had no parsable rows; showing full report.");
            if (result.stdout.len != 0) try writeLine(init.io, result.stdout);
            if (result.stderr.len != 0) try writeLine(init.io, result.stderr);
        }
    }

    if (full_report) {
        try writeLine(init.io, "== perf report (full) ==");
        try scripts.runChecked(init.io, &.{
            "perf",
            "report",
            "--stdio",
            "-i",
            perf_data,
            "--call-graph=graph",
            "--sort=symbol",
            "--percent-limit",
            perf_percent,
        }, root, true);
    }

    if (flamegraph) {
        const shell_cmd = try std.fmt.allocPrint(
            allocator,
            "perf script -i '{s}' | stackcollapse-perf.pl | flamegraph.pl > '{s}'",
            .{ perf_data, flamegraph_out },
        );
        scripts.runChecked(init.io, &.{ "sh", "-c", shell_cmd }, root, true) catch {
            try writeLine(init.io, "missing stackcollapse-perf.pl or flamegraph.pl in PATH");
            return;
        };
        try writeLine(init.io, try std.fmt.allocPrint(allocator, "wrote {s}", .{flamegraph_out}));
    }
}
