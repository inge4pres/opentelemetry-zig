const std = @import("std");

// Converts a key-value pair into a pbcommon.KeyValue.
// It only supports a subset of the possible value types available in attributes.
fn keyValue(comptime T: type) type {
    return struct {
        key: []const u8,
        value: T,

        fn resolve(self: keyValue(T)) Attribute {
            return Attribute{
                .name = self.key,
                .value = switch (@TypeOf(self.value)) {
                    bool => .{ .bool = self.value },
                    []const u8, [:0]const u8, *[:0]const u8 => .{ .string = self.value },
                    []u8, [:0]u8, *const [:0]u8 => .{ .string = self.value },
                    i64 => .{ .int = self.value },
                    f64 => .{ .double = self.value },
                    else => @compileError("unsupported value type for attribute " ++ @typeName(@TypeOf(self.value))),
                },
            };
        }
    };
}

pub const AttributeValue = union {
    bool: bool,
    string: []const u8,
    int: i64,
    double: f64,
};

pub const Attribute = struct {
    name: []const u8,
    value: AttributeValue,
};

/// Creates a slice of attributes from a list of key-value pairs.
/// Caller owns the memory.
pub const Attributes = struct {
    pub fn from(allocator: std.mem.Allocator, keyValues: anytype) !?[]Attribute {
        // Straight copied from the zig std library: std.fmt.
        // Check if the argument is a tuple.
        const ArgsType = @TypeOf(keyValues);
        const args_type_info = @typeInfo(ArgsType);
        if (args_type_info != .Struct) {
            @compileError("expected a tuple argument, found " ++ @typeName(ArgsType));
        }
        // Then check its length.
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

test "attributes are read from list of strings" {
    const val1: []const u8 = "value1";
    const val2: []const u8 = "value2";
    const attributes = try Attributes.from(std.testing.allocator, .{
        "name",  val1,
        "name2", val2,
        "name3", @as(i64, 456),
        "name4", false,
    });
    defer if (attributes) |a| std.testing.allocator.free(a);

    try std.testing.expect(attributes.?.len == 4);
    try std.testing.expectEqualStrings("name", attributes.?[0].name);
    try std.testing.expectEqualStrings("value1", attributes.?[0].value.string);
    try std.testing.expectEqualStrings("name2", attributes.?[1].name);
    try std.testing.expectEqualStrings("value2", attributes.?[1].value.string);
    try std.testing.expectEqual(@as(i64, 456), attributes.?[2].value.int);
    try std.testing.expectEqual(false, attributes.?[3].value.bool);
}

test "attributes from unit return null" {
    const attributes = try Attributes.from(std.testing.allocator, .{});
    defer if (attributes) |a| std.testing.allocator.free(a);
    try std.testing.expectEqual(null, attributes);
}
