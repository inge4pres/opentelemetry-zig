const std = @import("std");
const builtin = @import("builtin");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("opentelemetry/proto/common/v1.pb.zig");

// Converts a key-value pair into a pbcommon.KeyValue.
// It only supports a subset of the possible value types available in attributes.
fn keyValue(comptime T: type) type {
    return struct {
        key: []const u8,
        value: T,

        fn resolve(self: keyValue(T)) pbcommon.KeyValue {
            return pbcommon.KeyValue{
                .key = ManagedString.managed(self.key),
                .value = switch (@TypeOf(self.value)) {
                    bool => pbcommon.AnyValue{ .value = .{ .bool_value = self.value } },
                    []const u8 => pbcommon.AnyValue{ .value = .{ .string_value = ManagedString.managed(self.value) } },
                    []u8 => pbcommon.AnyValue{ .value = .{ .string_value = ManagedString.managed(self.value) } },
                    i64 => pbcommon.AnyValue{ .value = .{ .int_value = self.value } },
                    f64 => pbcommon.AnyValue{ .value = .{ .double_value = self.value } },
                    else => @compileError("unsupported value type for attribute " ++ @typeName(@TypeOf(self.value))),
                },
            };
        }
    };
}


//TODO convert this into an adapter from []Attribute to KeyValueList.
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
