const std = @import("std");
const a = @import("attributes.zig");
const Attribute = a.Attribute;
const Attributes = a.Attributes;

/// A measurement is a value recorded with an optional set of attributes.
/// It represents a single data point collected by an instrument.
pub fn Measurement(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        attributes: ?[]Attribute,

        pub fn with(value: T, attributes: ?[]Attribute) Measurement(T) {
            return Self{
                .value = value,
                .attributes = attributes,
            };
        }
    };
}

// test "measurement with attributes" {
//     const attrs = try Attributes.from(std.testing.allocator, .{ "name", 24 });
//     const m = Measurement(u32).with(42, attrs);
//     std.testing.expect(m.value == 42);
// }
