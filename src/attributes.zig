const std = @import("std");

// Converts a key-value pair into a pbcommon.KeyValue.
// It only supports a subset of the possible value types available in attributes.
fn keyValue(comptime T: type) type {
    return struct {
        key: []const u8,
        value: T,

        fn resolve(self: keyValue(T)) Attribute {
            return Attribute{
                .key = self.key,
                .value = switch (@TypeOf(self.value)) {
                    bool => .{ .bool = self.value },
                    []const u8, [:0]const u8, *[:0]const u8 => .{ .string = self.value },
                    []u8, [:0]u8, *const [:0]u8 => .{ .string = self.value },
                    i16, i32, i64, u16, u32, u64 => .{ .int = @intCast(self.value) },
                    f32, f64 => .{ .double = @floatCast(self.value) },
                    else => @compileError("unsupported value type for attribute " ++ @typeName(@TypeOf(self.value))),
                },
            };
        }
    };
}

/// Represents a value that can be stored in an Attribute.
pub const AttributeValue = union(enum) {
    bool: bool,
    string: []const u8,
    int: i64,
    double: f64,

    fn toString(self: AttributeValue, allocator: std.mem.Allocator) ![]const u8 {
        switch (self) {
            .bool => {
                const ret: []const u8 = if (self.bool) "0" else "1";
                return allocator.dupe(u8, ret);
            },
            .string => return allocator.dupe(u8, self.string),
            .int => {
                var buf = [_]u8{0} ** 64;
                const printed = std.fmt.formatIntBuf(&buf, self.int, 10, .lower, .{});
                return allocator.dupe(u8, buf[0..printed]);
            },
            .double => {
                var buf = [_]u8{0} ** 64;
                const printed = try std.fmt.formatFloat(&buf, self.double, .{});
                return allocator.dupe(u8, printed[0..printed.len]);
            },
        }
    }

    fn toStringNoAlloc(self: AttributeValue) []const u8 {
        switch (self) {
            .bool => return if (self.bool) "0" else "1",
            .string => return self.string,
            .int => {
                var buf = [_]u8{0} ** 64;
                const printed = std.fmt.formatIntBuf(&buf, self.int, 10, .lower, .{});
                return buf[0..printed];
            },
            .double => {
                var buf = [_]u8{0} ** 64;
                const printed = std.fmt.formatFloat(&buf, self.double, .{ .mode = .decimal, .precision = 6 }) catch "NaN";
                return printed[0..printed.len];
            },
        }
    }

    fn hash(self: AttributeValue) u64 {
        var h = std.hash.Wyhash.init(0);
        switch (self) {
            .bool => {
                const ret: []const u8 = if (self.bool) "0" else "1";
                h.update(ret);
            },
            .string => return h.update(self.string),
            .int => {
                var buf = [_]u8{0} ** 64;
                const printed = std.fmt.formatIntBuf(&buf, self.int, 10, .lower, .{});
                h.update(buf[0..printed]);
            },
            .double => {
                var buf = [_]u8{0} ** 64;
                const printed = try std.fmt.formatFloat(&buf, self.double, .{});
                h.update(printed[0..printed.len]);
            },
        }
        return h.final();
    }
};

/// Represents a key-value pair.
pub const Attribute = struct {
    key: []const u8,
    value: AttributeValue,

    // Caller owns the memory returned by this function and shold free it.
    fn toString(self: Attribute, allocator: std.mem.Allocator) ![]const u8 {
        var buf = [_]u8{0} ** 1024;
        const value = try self.value.toString(allocator);
        defer allocator.free(value);

        const ret = try std.fmt.bufPrint(&buf, "{s}:{s}", .{ self.key, value });
        return allocator.dupe(u8, ret[0..ret.len]);
    }
};

/// Creates a slice of attributes from a list of key-value pairs.
/// Caller owns the returned memory and should free the slice when done
/// through the same allocator.
pub const Attributes = struct {
    const Self = @This();
    attributes: ?[]Attribute = null,

    pub fn with(attributes: ?[]Attribute) Self {
        return Self{ .attributes = attributes };
    }

    pub const HashContext = struct {
        pub fn hash(_: HashContext, self: Self) u64 {
            var h = std.hash.Wyhash.init(0);
            const attrs = self.attributes orelse &[_]Attribute{};
            for (attrs) |attr| {
                h.update(attr.key);
                h.update(attr.value.toStringNoAlloc());
            }
            return h.final();
        }
        pub fn eql(_: HashContext, a: Self, b: Self) bool {
            const aAttrs = a.attributes orelse &[_]Attribute{};
            const bAttrs = b.attributes orelse &[_]Attribute{};
            if (aAttrs.len != bAttrs.len) {
                return false;
            }
            var compared: usize = 0;
            for (aAttrs) |aAttr| {
                for (bAttrs) |bAttr| {
                    if (std.mem.eql(u8, aAttr.key, bAttr.key) and std.meta.eql(aAttr.value, bAttr.value)) {
                        compared += 1;
                    }
                }
            }
            return compared == aAttrs.len;
        }
    };

    /// Creates a slice of attributes from a list of key-value pairs.
    /// Caller owns the returned memory and should free the slice when done via the same allocator.
    pub fn from(allocator: std.mem.Allocator, keyValues: anytype) !?[]Attribute {
        // Straight copied from the zig std library: std.fmt.
        // Check if the argument is a tuple.
        const ArgsType = @TypeOf(keyValues);
        const args_type_info = @typeInfo(ArgsType);
        if (args_type_info != .Struct) {
            @compileError("expected a tuple argument, found " ++ @typeName(ArgsType));
        }
        // Fast path: if the length is 0, return null.
        const fields_info = args_type_info.Struct.fields;
        if (fields_info.len == 0) {
            return null;
        }
        if (fields_info.len % 2 != 0) {
            @compileError("expected an even number of arguments");
        }

        var attrs: []Attribute = try allocator.alloc(Attribute, fields_info.len / 2);
        var key: []const u8 = undefined;
        comptime var i = 1;
        // Unroll the loop at compile time.
        inline for (std.meta.fields(ArgsType)) |kv| {
            const e = @field(keyValues, kv.name);
            if (i % 2 == 0) {
                const keyVal = keyValue(@TypeOf(e)){ .key = key, .value = e };
                attrs[i / 2 - 1] = keyVal.resolve();
            } else {
                key = e;
            }
            i += 1;
        }
        return attrs;
    }
};

test "attribute to string" {
    const attr = Attribute{ .key = "name", .value = .{ .string = "value" } };
    const str = try attr.toString(std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqualStrings("name:value", str);
}

test "attribute empty string to string" {
    const attrs = &[_]Attribute{};
    for (attrs) |attr| {
        const str = try attr.toString(std.testing.allocator);
        defer std.testing.allocator.free(str);
        try std.testing.expectEqualStrings("", str);
    }
}

test "attributes are read from list of strings" {
    const val1: []const u8 = "value1";
    const val2: []const u8 = "value2";
    const attributes = try Attributes.from(std.testing.allocator, .{
        "name",  val1,
        "name2", val2,
        "name3", @as(u64, 456),
        "name4", false,
    });
    defer if (attributes) |a| std.testing.allocator.free(a);

    try std.testing.expect(attributes.?.len == 4);
    try std.testing.expectEqualStrings("name", attributes.?[0].key);
    try std.testing.expectEqualStrings("value1", attributes.?[0].value.string);
    try std.testing.expectEqualStrings("name2", attributes.?[1].key);
    try std.testing.expectEqualStrings("value2", attributes.?[1].value.string);
    try std.testing.expectEqual(@as(i64, 456), attributes.?[2].value.int);
    try std.testing.expectEqual(false, attributes.?[3].value.bool);
}

test "attributes from unit return null" {
    const attributes = try Attributes.from(std.testing.allocator, .{});
    defer if (attributes) |a| std.testing.allocator.free(a);
    try std.testing.expectEqual(null, attributes);
}

test "attributes built for slice" {
    const val1: []const u8 = "value1";
    const val2: []const u8 = "value2";

    var list = [_]Attribute{
        .{ .key = "name", .value = .{ .string = val1 } },
        .{ .key = "name2", .value = .{ .string = val2 } },
        .{ .key = "name3", .value = .{ .int = @as(u64, 456) } },
        .{ .key = "name4", .value = .{ .bool = false } },
    };

    const attrs = Attributes.with(&list);
    try std.testing.expect(attrs.attributes.?.len == 4);
    try std.testing.expectEqualStrings("name", attrs.attributes.?[0].key);
    try std.testing.expectEqualStrings("value1", attrs.attributes.?[0].value.string);
    try std.testing.expectEqualStrings("name2", attrs.attributes.?[1].key);
    try std.testing.expectEqualStrings("value2", attrs.attributes.?[1].value.string);
    try std.testing.expectEqual(@as(i64, 456), attrs.attributes.?[2].value.int);
    try std.testing.expectEqual(false, attrs.attributes.?[3].value.bool);
}

test "attributes equality" {
    const val1: []const u8 = "value1";
    const val2: []const u8 = "value2";

    var list1 = [_]Attribute{
        .{ .key = "name", .value = .{ .string = val1 } },
        .{ .key = "name2", .value = .{ .string = val2 } },
        .{ .key = "name3", .value = .{ .int = @as(u64, 456) } },
        .{ .key = "name4", .value = .{ .bool = false } },
    };

    var list2 = [_]Attribute{
        .{ .key = "name", .value = .{ .string = val1 } },
        .{ .key = "name2", .value = .{ .string = val2 } },
        .{ .key = "name3", .value = .{ .int = @as(u64, 456) } },
        .{ .key = "name4", .value = .{ .bool = false } },
    };

    const a1 = Attributes.with(&list1);
    const a2 = Attributes.with(&list2);

    try std.testing.expectEqualDeep(a1, a2);
    try std.testing.expect(Attributes.HashContext.eql(Attributes.HashContext{}, a1, a2));
}
