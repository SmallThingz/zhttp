const std = @import("std");

const Allocator = std.mem.Allocator;

pub const CaptureError = error{
    MissingRequired,
    BadValue,
};

fn ParserValueType(comptime P: type) type {
    if (!@hasDecl(P, "get")) @compileError(@typeName(P) ++ " missing `get`");
    const fn_info = @typeInfo(@TypeOf(P.get));
    if (fn_info != .@"fn") @compileError(@typeName(P) ++ ".get is not a function");
    return fn_info.@"fn".return_type orelse @compileError(@typeName(P) ++ ".get must return a value");
}

fn isStructType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        else => false,
    };
}

pub fn structFields(comptime T: type) []const std.builtin.Type.StructField {
    const info = @typeInfo(T);
    return switch (info) {
        .@"struct" => info.@"struct".fields,
        else => @compileError("expected struct type, got " ++ @typeName(T)),
    };
}

pub fn emptyStruct(comptime T: type) T {
    var out: T = undefined;
    const fields = comptime structFields(T);
    inline for (fields) |f| {
        const P = f.type;
        if (!@hasDecl(P, "empty")) @compileError(@typeName(P) ++ " missing `pub const empty`");
        @field(out, f.name) = P.empty;
    }
    return out;
}

pub fn destroyStruct(value: anytype, allocator: Allocator) void {
    const T = @TypeOf(value.*);
    const fields = comptime structFields(T);
    inline for (fields) |f| {
        const P = f.type;
        if (!@hasDecl(P, "destroy")) @compileError(@typeName(P) ++ " missing `destroy`");
        @field(value.*, f.name).destroy(allocator);
    }
}

pub fn doneParsingStruct(value: anytype, present: []const bool) !void {
    const T = @TypeOf(value.*);
    const fields = comptime structFields(T);
    std.debug.assert(present.len == fields.len);
    inline for (fields, 0..) |f, i| {
        const P = f.type;
        if (!@hasDecl(P, "doneParsing")) @compileError(@typeName(P) ++ " missing `doneParsing`");
        try @field(value.*, f.name).doneParsing(present[i]);
    }
}

fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn fnv1a64HeaderKey(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        const c: u8 = if (b == '_') '-' else asciiLower(b);
        h ^= c;
        h *%= 0x100000001b3;
    }
    return h;
}

fn asciiEqHeaderKeyIgnoreCase(input: []const u8, field_name: []const u8) bool {
    if (input.len != field_name.len) return false;
    for (input, field_name) |ic, fc0| {
        const fc: u8 = if (fc0 == '_') '-' else fc0;
        if (asciiLower(ic) != asciiLower(fc)) return false;
    }
    return true;
}

fn headerFieldNamesClash(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac0, bc0| {
        const ac: u8 = if (ac0 == '_') '-' else ac0;
        const bc: u8 = if (bc0 == '_') '-' else bc0;
        if (asciiLower(ac) != asciiLower(bc)) return false;
    }
    return true;
}

fn nextPow2AtLeast(comptime n: usize, comptime min: usize) usize {
    var x: usize = if (n < min) min else n;
    x -= 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    if (@sizeOf(usize) == 8) x |= x >> 32;
    return x + 1;
}

pub const LookupKind = enum { header, query };

pub fn Lookup(comptime T: type, comptime kind: LookupKind) type {
    if (!isStructType(T)) @compileError("expected struct type, got " ++ @typeName(T));
    const fields = structFields(T);

    const keys = comptime blk: {
        var out: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| {
            out[i] = f.name;
        }
        break :blk out;
    };

    // Detect duplicate keys at comptime (after normalization).
    comptime {
        for (keys, 0..) |ka, i| {
            for (keys, 0..) |kb, j| {
                if (i >= j) continue;
                const clash = switch (kind) {
                    .header => headerFieldNamesClash(ka, kb),
                    .query => std.mem.eql(u8, ka, kb),
                };
                if (clash) {
                    @compileError("duplicate capture key: " ++ ka);
                }
            }
        }
    }

    const hashes = comptime blk: {
        var out: [fields.len]u64 = undefined;
        for (keys, 0..) |k, i| {
            out[i] = switch (kind) {
                .header => fnv1a64HeaderKey(k),
                .query => fnv1a64(k),
            };
        }
        break :blk out;
    };

    const table_cap: usize = nextPow2AtLeast(fields.len * 2 + 1, 8);

    const table = comptime blk: {
        var t: [table_cap]u16 = .{0} ** table_cap;
        const mask: u64 = table_cap - 1;
        for (hashes, 0..) |h, idx| {
            var pos: u64 = h & mask;
            while (true) : (pos = (pos + 1) & mask) {
                if (t[@intCast(pos)] == 0) {
                    t[@intCast(pos)] = @intCast(idx + 1);
                    break;
                }
            }
        }
        break :blk t;
    };

    return struct {
        pub const count: usize = fields.len;
        pub const key_list: [fields.len][]const u8 = keys;
        pub const hash_list: [fields.len]u64 = hashes;
        pub const table_list: [table_cap]u16 = table;

        pub fn find(name: []const u8) ?u16 {
            if (count == 0) return null;
            const h = switch (kind) {
                .header => fnv1a64HeaderKey(name),
                .query => fnv1a64(name),
            };
            const mask: u64 = table_cap - 1;
            var pos: u64 = h & mask;
            var probe: usize = 0;
            while (probe < table_cap) : (probe += 1) {
                const slot = table_list[@intCast(pos)];
                if (slot == 0) return null;
                const idx: u16 = slot - 1;
                if (hash_list[idx] == h) {
                    const k = key_list[idx];
                    const ok = switch (kind) {
                        .header => asciiEqHeaderKeyIgnoreCase(name, k),
                        .query => std.mem.eql(u8, name, k),
                    };
                    if (ok) return idx;
                }
                pos = (pos + 1) & mask;
            }
            return null;
        }
    };
}

pub fn mergeStructs(comptime A: type, comptime B: type) type {
    if (!isStructType(A) or !isStructType(B)) @compileError("mergeStructs expects struct types");
    const fa = structFields(A);
    const fb = structFields(B);

    comptime var names_count: usize = fa.len;
    for (fb) |f| {
        comptime var exists = false;
        for (fa) |g| {
            if (std.mem.eql(u8, f.name, g.name)) {
                exists = true;
                if (f.type != g.type) {
                    @compileError("conflicting capture field '" ++ f.name ++ "'");
                }
            }
        }
        if (!exists) names_count += 1;
    }

    const names = comptime blk: {
        var n: [names_count][]const u8 = undefined;
        var i: usize = 0;
        for (fa) |f| {
            n[i] = f.name;
            i += 1;
        }
        for (fb) |f| {
            var exists = false;
            for (fa) |g| {
                if (std.mem.eql(u8, f.name, g.name)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                n[i] = f.name;
                i += 1;
            }
        }
        break :blk n;
    };

    const types = comptime blk: {
        var t: [names_count]type = undefined;
        for (names, 0..) |name, i| {
            if (@hasField(A, name)) {
                t[i] = @FieldType(A, name);
            } else {
                t[i] = @FieldType(B, name);
            }
        }
        break :blk t;
    };

    const attrs = comptime blk: {
        var a: [names_count]std.builtin.Type.StructField.Attributes = undefined;
        for (&a) |*x| x.* = .{};
        break :blk a;
    };

    return @Struct(.auto, null, names[0..], &types, &attrs);
}

pub fn mergeStructsMany(comptime types_tuple: anytype) type {
    const Ti = @TypeOf(types_tuple);
    const info = @typeInfo(Ti);
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("mergeStructsMany expects tuple of types");
    const fields = info.@"struct".fields;
    if (fields.len == 0) return struct {};
    comptime var acc: type = @field(types_tuple, fields[0].name);
    for (fields[1..]) |f| {
        const T = @field(types_tuple, f.name);
        acc = mergeStructs(acc, T);
    }
    return acc;
}

/// Parse and store a required path-param string without allocating.
///
/// This is safe for path params because zhttp copies all path params into stable
/// request-owned storage before parsing captures.
pub const PathString = String;

/// Parse and store a required UTF-8-ish string (no validation).
pub const String = struct {
    value: []const u8 = undefined,

    pub const empty: String = .{ .value = "" };

    pub fn parse(self: *String, _: Allocator, raw: []const u8) !void {
        self.value = raw;
    }

    pub fn doneParsing(_: *String, was_present: bool) !void {
        if (!was_present) return error.MissingRequired;
    }

    pub fn get(self: *const String) []const u8 {
        return self.value;
    }

    pub fn destroy(self: *String, _: Allocator) void {
        self.* = .{ .value = "" };
    }
};

pub fn Optional(comptime P: type) type {
    return struct {
        present: bool = false,
        inner: P = .empty,

        pub const empty: @This() = .{};

        pub fn parse(self: *@This(), allocator: Allocator, raw: []const u8) !void {
            try self.inner.parse(allocator, raw);
        }

        pub fn doneParsing(self: *@This(), was_present: bool) !void {
            self.present = was_present;
            if (was_present) try self.inner.doneParsing(true);
        }

        pub fn get(self: *const @This()) ?ParserValueType(P) {
            return if (!self.present) null else self.inner.get();
        }

        pub fn destroy(self: *@This(), allocator: Allocator) void {
            self.present = false;
            self.inner.destroy(allocator);
        }
    };
}

pub fn Int(comptime T: type) type {
    return struct {
        value: T = undefined,
        pub const empty: @This() = .{};

        pub fn parse(self: *@This(), _: Allocator, raw: []const u8) !void {
            self.value = std.fmt.parseInt(T, raw, 10) catch return error.BadValue;
        }

        pub fn doneParsing(_: *@This(), was_present: bool) !void {
            if (!was_present) return error.MissingRequired;
        }

        pub fn get(self: *const @This()) T {
            return self.value;
        }

        pub fn destroy(self: *@This(), _: Allocator) void {
            self.* = .{};
        }
    };
}

pub fn Float(comptime T: type) type {
    return struct {
        value: T = undefined,
        pub const empty: @This() = .{};

        pub fn parse(self: *@This(), _: Allocator, raw: []const u8) !void {
            self.value = std.fmt.parseFloat(T, raw) catch return error.BadValue;
        }

        pub fn doneParsing(_: *@This(), was_present: bool) !void {
            if (!was_present) return error.MissingRequired;
        }

        pub fn get(self: *const @This()) T {
            return self.value;
        }

        pub fn destroy(self: *@This(), _: Allocator) void {
            self.* = .{};
        }
    };
}

pub const Bool = struct {
    value: bool = undefined,
    pub const empty: Bool = .{};

    pub fn parse(self: *Bool, _: Allocator, raw: []const u8) !void {
        self.value = try switch (raw.len) {
            1 => switch (raw[0]) {
                '1' => true,
                '0' => false,
                else => error.BadValue,
            },
            4 => if (std.ascii.eqlIgnoreCase(raw, "true")) true else error.BadValue,
            5 => if (std.ascii.eqlIgnoreCase(raw, "false")) false else error.BadValue,
            else => error.BadValue,
        };
    }

    pub fn doneParsing(_: *Bool, was_present: bool) !void {
        if (!was_present) return error.MissingRequired;
    }

    pub fn get(self: *const Bool) bool {
        return self.value;
    }

    pub fn destroy(self: *Bool, _: Allocator) void {
        self.* = .{};
    }
};

pub fn Enum(comptime E: type) type {
    return struct {
        value: E = undefined,
        pub const empty: @This() = .{};

        pub fn parse(self: *@This(), _: Allocator, raw: []const u8) !void {
            self.value = std.meta.stringToEnum(E, raw) orelse return error.BadValue;
        }

        pub fn doneParsing(_: *@This(), was_present: bool) !@This() {
            if (!was_present) return error.MissingRequired;
        }

        pub fn get(self: *const @This()) E {
            return self.value;
        }

        pub fn destroy(self: *@This(), _: Allocator) void {
            self.* = undefined;
        }
    };
}

pub fn SliceOf(comptime P: type) type {
    return struct {
        list: std.ArrayListUnmanaged(P) = .empty,
        pub const empty: @This() = .{};

        pub fn parse(self: *@This(), allocator: Allocator, raw: []const u8) !void {
            var tmp: P = P.empty;
            try tmp.parse(allocator, raw);
            try tmp.doneParsing(true);
            try self.list.append(allocator, tmp);
        }

        pub fn doneParsing(self: *@This(), was_present: bool) !void {
            _ = self;
            _ = was_present;
        }

        pub fn get(self: *const @This()) []const P {
            return self.list.items;
        }

        pub fn destroy(self: *@This(), allocator: Allocator) void {
            for (self.list.items) |*v| v.destroy(allocator);
            self.list.deinit(allocator);
            self.* = .empty;
        }
    };
}

test "Lookup: header find is case-insensitive and '_' matches '-'" {
    const H = struct {
        content_type: Optional(String),
        host: Optional(String),
    };
    const L = Lookup(H, .header);
    try std.testing.expectEqual(@as(?u16, 0), L.find("Content-Type"));
    try std.testing.expectEqual(@as(?u16, 0), L.find("content-type"));
    try std.testing.expectEqual(@as(?u16, 1), L.find("HOST"));
    try std.testing.expectEqual(@as(?u16, null), L.find("x-nope"));
}

test "Lookup: query find is case-sensitive" {
    const Q = struct {
        page: Optional(Int(u32)),
    };
    const L = Lookup(Q, .query);
    try std.testing.expectEqual(@as(?u16, 0), L.find("page"));
    try std.testing.expectEqual(@as(?u16, null), L.find("Page"));
}

test "mergeStructs: merges without losing fields" {
    const A = struct { a: Int(u32), b: Optional(String) };
    const B = struct { b: Optional(String), c: Bool };
    const M = mergeStructs(A, B);
    comptime {
        const mf = structFields(M);
        std.debug.assert(mf.len == 3);
        std.debug.assert(std.mem.eql(u8, mf[0].name, "a"));
        std.debug.assert(std.mem.eql(u8, mf[1].name, "b"));
        std.debug.assert(std.mem.eql(u8, mf[2].name, "c"));
    }
}

test "String: parse duplicates and destroy resets" {
    var s: String = .{};
    const gpa = std.testing.allocator;
    try s.parse(gpa, "hello");
    try s.doneParsing(true);
    try std.testing.expectEqualStrings("hello", s.get());
    s.destroy(gpa);
    try std.testing.expectEqualStrings("", s.get());
}

test "Optional(String): get returns null when missing" {
    const Opt = Optional(String);
    var o: Opt = .{};
    const gpa = std.testing.allocator;
    try o.doneParsing(false);
    try std.testing.expect(o.get() == null);
    try o.parse(gpa, "x");
    try o.doneParsing(true);
    try std.testing.expectEqualStrings("x", o.get().?);
    o.destroy(gpa);
    try std.testing.expect(o.get() == null);
}

test "SliceOf(String): collects and owns entries" {
    const L = SliceOf(String);
    var l: L = .{};
    const gpa = std.testing.allocator;
    defer l.destroy(gpa);
    try l.parse(gpa, "one");
    try l.parse(gpa, "two");
    try l.doneParsing(true);
    const items = l.get();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("one", items[0].get());
    try std.testing.expectEqualStrings("two", items[1].get());
}

test "fuzz: String/Optional/SliceOf/Int/Bool/Float" {
    const corpus = &.{
        "hello",
        "123",
        "-1",
        "true",
        "1",
        "0",
        "3.14",
        "NaN",
    };
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            const gpa = std.testing.allocator;
            var buf: [128]u8 = undefined;
            const max: u16 = @intCast(buf.len);
            const len_u16 = smith.valueRangeAtMost(u16, 0, max);
            const len: usize = @intCast(len_u16);
            smith.bytes(buf[0..len]);
            const raw = buf[0..len];

            var s: String = .{};
            try s.parse(gpa, raw);
            try s.doneParsing(true);
            try std.testing.expectEqualSlices(u8, raw, s.get());
            s.destroy(gpa);

            const Opt = Optional(String);
            var o: Opt = .{};
            if (smith.value(bool)) {
                try o.parse(gpa, raw);
                try o.doneParsing(true);
            } else {
                _ = o.doneParsing(false) catch {};
            }
            o.destroy(gpa);

            const L = SliceOf(String);
            var l: L = .{};
            defer l.destroy(gpa);
            const items = smith.valueRangeAtMost(u8, 0, 3);
            var i: u8 = 0;
            while (i < items) : (i += 1) {
                try l.parse(gpa, raw);
            }
            try l.doneParsing(items != 0);
            _ = l.get();

            const I = Int(u32);
            var iv: I = .{};
            _ = iv.parse(gpa, raw) catch {};
            _ = iv.doneParsing(true) catch {};
            iv.destroy(gpa);

            const B = Bool;
            var bv: B = .{};
            _ = bv.parse(gpa, raw) catch {};
            _ = bv.doneParsing(true) catch {};
            bv.destroy(gpa);

            const F = Float(f64);
            var fv: F = .{};
            _ = fv.parse(gpa, raw) catch {};
            _ = fv.doneParsing(true) catch {};
            fv.destroy(gpa);
        }
    }.testOne, .{ .corpus = corpus });
}
