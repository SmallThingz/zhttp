const middleware = @import("../middleware.zig");
const std = @import("std");

pub const MiddlewareInfo = middleware.MiddlewareInfo;
pub const Static = middleware.Static;
pub const Cors = middleware.Cors;
pub const Logger = middleware.Logger;
pub const Compression = middleware.Compression;
pub const Origin = middleware.Origin;
pub const OriginDecisionTree = middleware.OriginDecisionTree;
pub const OriginHashMatcher = middleware.OriginHashMatcher;
pub const Timeout = middleware.Timeout;
pub const Etag = middleware.Etag;
pub const RequestId = middleware.RequestId;
pub const SecurityHeaders = middleware.SecurityHeaders;

test "mod forwards canonical middleware exports" {
    try std.testing.expect(MiddlewareInfo == middleware.MiddlewareInfo);
    try std.testing.expect(Static == middleware.Static);
    try std.testing.expect(Cors == middleware.Cors);
    try std.testing.expect(Logger == middleware.Logger);
    try std.testing.expect(Compression == middleware.Compression);
    try std.testing.expect(Origin == middleware.Origin);
    try std.testing.expect(OriginDecisionTree == middleware.OriginDecisionTree);
    try std.testing.expect(OriginHashMatcher == middleware.OriginHashMatcher);
    try std.testing.expect(Timeout == middleware.Timeout);
    try std.testing.expect(Etag == middleware.Etag);
    try std.testing.expect(RequestId == middleware.RequestId);
    try std.testing.expect(SecurityHeaders == middleware.SecurityHeaders);
}
