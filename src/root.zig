//! zhttp: low-latency HTTP/1.1 server primitives.
pub const Method = @import("zhttp/server.zig").Method;
pub const Res = @import("zhttp/response.zig").Res;
pub const Server = @import("zhttp/server.zig").Server;

pub const parse = @import("zhttp/parse.zig");

pub const route = @import("zhttp/router.zig").route;
pub const get = @import("zhttp/router.zig").get;
pub const post = @import("zhttp/router.zig").post;
pub const put = @import("zhttp/router.zig").put;
pub const delete = @import("zhttp/router.zig").delete;
pub const patch = @import("zhttp/router.zig").patch;
pub const head = @import("zhttp/router.zig").head;
pub const options = @import("zhttp/router.zig").options;

test {
    _ = @import("zhttp/tests.zig");
}
