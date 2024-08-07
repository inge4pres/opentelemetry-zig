const std = @import("std");
const protobuf = @import("protobuf");
const pbcommon = @import("opentelemetry/proto/common/v1.pb.zig");

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
