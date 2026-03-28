const operations = @import("../operations.zig");
const std = @import("std");

pub const RouteDecl = operations.RouteDecl;
pub const Router = operations.Router;
/// Built-in operation that synthesizes CORS preflight `OPTIONS` routes.
pub const Cors = operations.Cors;
/// Built-in operation that synthesizes static middleware mount routes.
pub const Static = operations.Static;

test "mod forwards canonical operations exports" {
    try std.testing.expect(RouteDecl == operations.RouteDecl);
    try std.testing.expect(Router == operations.Router);
    try std.testing.expect(Cors == operations.Cors);
    try std.testing.expect(Static == operations.Static);
}
