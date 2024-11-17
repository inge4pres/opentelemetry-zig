const std = @import("std");
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const Kind = @import("instrument.zig").Kind;
const InstrumentOptions = @import("instrument.zig").InstrumentOptions;

/// A value recorded with an optional set of attributes.
/// It represents a single data point collected from an instrument.
pub fn DataPoint(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        attributes: ?[]Attribute = null,
        // TODO: consider adding a timestamp field
    };
}

test "datapoint with attributes" {
    const key = "name";
    const attrs = try Attributes.from(std.testing.allocator, .{ key, true });
    defer std.testing.allocator.free(attrs.?);

    const m = DataPoint(u32){ .value = 42, .attributes = attrs };
    try std.testing.expect(m.value == 42);
}

/// A union of measurements with either integer or double values.
/// This is used to represent the data collected by a meter.
pub const MeasurementsData = union(enum) {
    int: []DataPoint(i64),
    double: []DataPoint(f64),

    pub fn deinit(self: MeasurementsData, allocator: std.mem.Allocator) void {
        switch (self) {
            .int => allocator.free(self.int),
            .double => allocator.free(self.double),
        }
    }
};

/// A set of data points with a series of metadata coming from the meter and the instrument.
/// It holds the data collected by a single instrument inside a meter.
pub const Measurements = struct {
    meterName: []const u8,
    meterAttributes: ?[]Attribute = null,
    meterSchemaUrl: ?[]const u8 = null,

    instrumentKind: Kind,
    instrumentOptions: InstrumentOptions,

    data: MeasurementsData,

    pub fn deinit(self: *Measurements, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }
};
