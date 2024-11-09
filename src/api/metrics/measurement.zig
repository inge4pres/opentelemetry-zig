const std = @import("std");
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;

/// A measurement is a value recorded with an optional set of attributes.
/// It represents a single data point collected from an instrument.
pub fn Measurement(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        attributes: ?[]Attribute = null,
    };
}

test "measurement with attributes" {
    const key = "name";
    const attrs = try Attributes.from(std.testing.allocator, .{ key, true });
    defer std.testing.allocator.free(attrs.?);

    const m = Measurement(u32){ .value = 42, .attributes = attrs };
    try std.testing.expect(m.value == 42);
}
