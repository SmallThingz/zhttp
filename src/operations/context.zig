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
