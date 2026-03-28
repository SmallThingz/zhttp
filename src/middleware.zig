pub const MiddlewareInfo = struct {
    name: @TypeOf(.middleware),
    data: ?type = null,
    path: ?type = null,
    query: ?type = null,
    header: ?type = null,
};

pub const Static = @import("middleware/static.zig").Static;
pub const Cors = @import("middleware/cors.zig").Cors;
pub const Logger = @import("middleware/logger.zig").Logger;
pub const Compression = @import("middleware/compression.zig").Compression;
pub const Origin = @import("middleware/origin.zig").Origin;
pub const OriginDecisionTree = @import("middleware/origin.zig").DecisionTree;
pub const OriginHashMatcher = @import("middleware/origin.zig").HashMatcher;
pub const Timeout = @import("middleware/timeout.zig").Timeout;
pub const Etag = @import("middleware/etag.zig").Etag;
pub const RequestId = @import("middleware/request_id.zig").RequestId;
pub const SecurityHeaders = @import("middleware/security_headers.zig").SecurityHeaders;
