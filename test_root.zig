const std = @import("std");
const zhttp = @import("src/root.zig");

test "loopback listen preflight" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var listener = try std.Io.net.IpAddress.listen(addr0, io, .{ .reuse_address = true });
    listener.deinit(io);
}

test {
    _ = zhttp;
}
