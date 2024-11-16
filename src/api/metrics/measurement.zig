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

/// A union of measurements with either integer or double values.
/// This is used to represent the data collected by a meter.
pub const MeasurementsData = union(enum) {
    int: []Measurement(i64),
    double: []Measurement(f64),

    pub fn deinit(self: MeasurementsData, allocator: std.mem.Allocator) void {
        switch (self) {
            .int => allocator.free(self.int),
            .double => allocator.free(self.double),
        }
    }
};

/// A set of measurements with a schema URL and optional attributes,
/// representing the data collected by a meter.
pub const MeterMeasurements = struct {
    name: []const u8,
    attributes: ?[]Attribute,
    schemaUrl: ?[]const u8,
    data: MeasurementsData,

    pub fn deinit(self: *MeterMeasurements, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        allocator.destroy(self);
    }
};
