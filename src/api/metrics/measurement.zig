const std = @import("std");
const ArrayList = std.ArrayList;

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

        pub fn new(allocator: std.mem.Allocator, value: T, attributes: anytype) std.mem.Allocator.Error!Self {
            return Self{ .value = value, .attributes = try Attributes.from(allocator, attributes) };
        }

        pub fn dupe(self: Self, allocator: std.mem.Allocator) !Self {
            const duped_attrs = try Attributes.with(self.attributes).dupe(allocator);
            return Self{ .value = self.value, .attributes = duped_attrs };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.attributes) |a| allocator.free(a);
        }
    };
}

test "datapoint without attributes" {
    var m = try DataPoint(u32).new(std.testing.allocator, 42, .{});
    defer m.deinit(std.testing.allocator);

    try std.testing.expect(m.value == 42);
    try std.testing.expectEqual(null, m.attributes);
}

test "datapoint with attributes" {
    const val: []const u8 = "name";
    var m = try DataPoint(u32).new(std.testing.allocator, 42, .{ "anykey", val });
    defer m.deinit(std.testing.allocator);
    try std.testing.expect(m.value == 42);
}

/// A union of measurements with either integer or double values.
/// This is used to represent the data collected by a meter.
pub const MeasurementsData = union(enum) {
    int: []DataPoint(i64),
    double: []DataPoint(f64),
};

/// A set of data points with a series of metadata coming from the meter and the instrument.
/// Holds the data collected by a single instrument inside a meter.
pub const Measurements = struct {
    meterName: []const u8,
    meterAttributes: ?[]Attribute = null,
    meterSchemaUrl: ?[]const u8 = null,

    instrumentKind: Kind,
    instrumentOptions: InstrumentOptions,

    data: MeasurementsData,

    pub fn deinit(self: *Measurements, allocator: std.mem.Allocator) void {
        switch (self.data) {
            inline else => |list| {
                for (list) |*dp| dp.deinit(allocator);
                allocator.free(list);
            },
        }
    }
};
