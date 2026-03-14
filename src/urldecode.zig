const std = @import("std");

pub const DecodeMode = enum {
    path_param,
    query_value,
};

pub const DecodeError = error{
    InvalidPercentEncoding,
};

fn fromHex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Percent-decodes into the same buffer, returning the decoded slice.
/// Does not move bytes outside `buf`; compaction happens only within the slice.
pub fn decodeInPlace(buf: []u8, comptime mode: DecodeMode) DecodeError![]u8 {
    var r: usize = 0;
    var w: usize = 0;
    while (r < buf.len) : (r += 1) {
        const c = buf[r];
        if (comptime mode == .query_value) {
            if (c == '+') {
                buf[w] = ' ';
                w += 1;
                continue;
            }
        }
        if (c == '%') {
            if (r + 2 >= buf.len) return error.InvalidPercentEncoding;
            const hi = fromHex(buf[r + 1]) orelse return error.InvalidPercentEncoding;
            const lo = fromHex(buf[r + 2]) orelse return error.InvalidPercentEncoding;
            buf[w] = (hi << 4) | lo;
            w += 1;
            r += 2;
            continue;
        }
        buf[w] = c;
        w += 1;
    }
    return buf[0..w];
}

test decodeInPlace {
    var buf1 = "a%20b".*;
    const out1 = try decodeInPlace(buf1[0..], .query_value);
    try std.testing.expectEqualStrings("a b", out1);

    var buf2 = "a+b".*;
    const out2 = try decodeInPlace(buf2[0..], .query_value);
    try std.testing.expectEqualStrings("a b", out2);

    var buf3 = "%2F".*;
    const out3 = try decodeInPlace(buf3[0..], .path_param);
    try std.testing.expectEqualStrings("/", out3);
}

test "decodeInPlace: invalid percent sequences rejected" {
    var a = "%".*;
    try std.testing.expectError(error.InvalidPercentEncoding, decodeInPlace(a[0..], .path_param));

    var b = "%1".*;
    try std.testing.expectError(error.InvalidPercentEncoding, decodeInPlace(b[0..], .path_param));

    var c = "%GG".*;
    try std.testing.expectError(error.InvalidPercentEncoding, decodeInPlace(c[0..], .path_param));

    var d = "x%G0y".*;
    try std.testing.expectError(error.InvalidPercentEncoding, decodeInPlace(d[0..], .path_param));
}

test "decodeInPlace: '+' is only space in query_value mode" {
    var q = "a+b".*;
    const out_q = try decodeInPlace(q[0..], .query_value);
    try std.testing.expectEqualStrings("a b", out_q);

    var p = "a+b".*;
    const out_p = try decodeInPlace(p[0..], .path_param);
    try std.testing.expectEqualStrings("a+b", out_p);
}

test "decodeInPlace: compaction stays within slice" {
    var buf = "a%2Fb".*;
    const out = try decodeInPlace(buf[0..], .path_param);
    try std.testing.expectEqualStrings("a/b", out);
    try std.testing.expect(out.len == 3);
}
