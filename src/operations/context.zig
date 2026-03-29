/// Compile-time operation context passed into `operation(...)`.
pub const OperationCtx = struct {
    /// Operation type currently being executed.
    operation: type,
    /// Concrete router type used for this operation run.
    router_type: type,

    /// Returns the concrete router pointer type used by this operation.
    pub fn T(comptime self: @This()) type {
        return *self.router_type;
    }

    /// Returns indices of routes tagged with this operation.
    pub fn filter(comptime self: @This(), r: self.T()) []const usize {
        return r.filterByOperation(self.operation);
    }
};

test "OperationCtx: T and filter delegate to router" {
    const std = @import("std");

    const Op = struct {};
    const FakeRouter = struct {
        called: bool = false,

        pub fn filterByOperation(self: *@This(), comptime operation: type) []const usize {
            comptime {
                if (operation != Op) @compileError("OperationCtx.filter passed wrong operation type");
            }
            self.called = true;
            return &.{ 1, 3, 5 };
        }
    };

    const opctx: OperationCtx = .{
        .operation = Op,
        .router_type = FakeRouter,
    };
    try std.testing.expect(opctx.T() == *FakeRouter);

    var router: FakeRouter = .{};
    const indices = opctx.filter(&router);
    try std.testing.expect(router.called);
    try std.testing.expectEqual(@as(usize, 3), indices.len);
    try std.testing.expectEqual(@as(usize, 3), indices[1]);
}

test "OperationCtx: empty filter result is passed through unchanged" {
    const std = @import("std");

    const Op = struct {};
    const FakeRouter = struct {
        pub fn filterByOperation(_: *@This(), comptime operation: type) []const usize {
            comptime {
                if (operation != Op) @compileError("wrong operation type");
            }
            return &.{};
        }
    };

    const opctx: OperationCtx = .{
        .operation = Op,
        .router_type = FakeRouter,
    };
    var router: FakeRouter = .{};
    try std.testing.expectEqual(@as(usize, 0), opctx.filter(&router).len);
}
