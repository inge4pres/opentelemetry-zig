const std = @import("std");
const builtin = @import("builtin");
const protobuf = @import("protobuf");
const pbcommon = @import("opentelemetry/proto/common/v1.pb.zig");
// const ManagedString = protobuf.ManagedString;

/// Generate a hash identifier from a set of attributes. The hash is made from both keys and values.
/// The hash is used to identify the counter for a given set of attributes and
/// alow incrementing it without allocating memory for each set of attributes.
/// A limit of 4096 bytes is imposed on the hashed content; there should be no collisions
/// between different sets of attributes with such a limit.
pub fn hashIdentifyAttributes(attributes: ?pbcommon.KeyValueList) u64 {
    if (attributes) |a| {
        var hash: [4096]u8 = std.mem.zeroes([4096]u8);
        var nextInsertIdx: usize = 0;
        for (a.values.items) |kv| {
            const buf = std.mem.toBytes(kv);
            // If the attributes are not going to fit, we stop hashing them.
            if (nextInsertIdx + buf.len > 4095) {
                break;
            }
            for (buf) |v| {
                hash[nextInsertIdx] = v;
            }
            nextInsertIdx += buf.len;
        }
        return std.hash.XxHash3.hash(0, &hash);
    } else {
        return 0;
    }
}

test "null attributes generate zero hash value" {
    const key = hashIdentifyAttributes(null);
    try std.testing.expectEqual(0, key);
}

test "generate map key from attributes" {
    var attrs = pbcommon.KeyValueList{ .values = std.ArrayList(pbcommon.KeyValue).init(std.testing.allocator) };
    defer attrs.values.deinit();

    try attrs.values.append(pbcommon.KeyValue{ .key = .{ .Const = "string_key" }, .value = pbcommon.AnyValue{ .value = .{ .string_value = .{ .Const = "some_string" } } } });
    try attrs.values.append(pbcommon.KeyValue{ .key = .{ .Const = "bool_key" }, .value = pbcommon.AnyValue{ .value = .{ .bool_value = true } } });
    try attrs.values.append(pbcommon.KeyValue{ .key = .{ .Const = "integer_key" }, .value = pbcommon.AnyValue{ .value = .{ .int_value = 42 } } });
    std.debug.assert(attrs.values.items.len == 3);

    const key = hashIdentifyAttributes(attrs);
    try std.testing.expectEqual(0x93d76fe148c689ba, key);
}

// Converts a key-value pair into a pbcommon.KeyValue.
// It only supports a subset of the possible value types available in attributes.
fn keyValue(comptime T: type) type {
    return struct {
        key: []const u8,
        value: T,

        fn resolve(self: keyValue(T)) pbcommon.KeyValue {
            return pbcommon.KeyValue{
                .key = .{ .Const = self.key },
                .value = switch (@TypeOf(self.value)) {
                    bool => pbcommon.AnyValue{ .value = .{ .bool_value = self.value } },
                    []const u8 => pbcommon.AnyValue{ .value = .{ .string_value = .{ .Const = self.value } } },
                    i64 => pbcommon.AnyValue{ .value = .{ .int_value = self.value } },
                    f64 => pbcommon.AnyValue{ .value = .{ .double_value = self.value } },
                    else => @compileError("unsupported value type for attribute " ++ @typeName(@TypeOf(self.value))),
                },
            };
        }
    };
}

/// Helper function to create a KeyValueList from a variadic list of key-value pairs.
/// Call this function with an allocator and a tuple containing key-value pairs.
/// Each key-value pair will be formed by two consecutive values in the tuple.
/// That means the 0th and all the even entries will be keys, and the 1st and all the odd entries will be values.
/// The returned ArrayList must be deinitialized by the caller.
pub fn WithAttributes(allocator: std.mem.Allocator, args: anytype) !pbcommon.KeyValueList {
    var attrs = pbcommon.KeyValueList{ .values = std.ArrayList(pbcommon.KeyValue).init(allocator) };

    // Straight copied from the zig std library: std.fmt.
    // Check if the argument is a tuple.
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .Struct) {
        @compileError("expected a tuple argument, found " ++ @typeName(ArgsType));
    }
    // Then check its length.
    const fields_info = args_type_info.Struct.fields;
    if (fields_info.len % 2 != 0) {
        @compileError("expected an even number of arguments");
    }

    // Build a key-value pair from the tuple, traversing in order.
    var key: []const u8 = undefined;
    comptime var i = 1;
    // Unroll the loop at compile time.
    inline for (std.meta.fields(ArgsType)) |kv| {
        const e = @field(args, kv.name);
        if (i % 2 == 0) {
            const keyVal = keyValue(@TypeOf(e)){ .key = key, .value = e };
            try attrs.values.append(keyVal.resolve());
        } else {
            key = e;
        }
        i += 1;
    }

    return attrs;
}

test "WithAttributes key value helper" {
    const abc: []const u8 = "some_string";
    const attributes = try WithAttributes(std.testing.allocator, .{ "string_key", abc, "bool_key", true, "integer_key", @as(i64, 42) });
    defer attributes.values.deinit();

    std.debug.assert(attributes.values.items.len == 3);
}
