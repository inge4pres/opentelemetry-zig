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
        timestamps: ?Timestamps = null, // Timestamps are filled in when extracting data points from the meter.

        /// Creates a data points with the provided value and attributes,
        /// adding a timestamp with the current time.
        pub fn new(allocator: std.mem.Allocator, value: T, attributes: anytype) std.mem.Allocator.Error!Self {
            return Self{
                .value = value,
                .attributes = try Attributes.from(allocator, attributes),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            switch (T) {
                HistogramDataPoint => allocator.free(self.value.bucket_counts),
                else => {},
            }
            if (self.attributes) |a| allocator.free(a);
        }

        pub fn deepCopy(self: Self, allocator: std.mem.Allocator) !Self {
            return Self{
                .value = switch (T) {
                    HistogramDataPoint => HistogramDataPoint{
                        .bucket_counts = try allocator.dupe(u64, self.value.bucket_counts),
                        .explicit_bounds = self.value.explicit_bounds,
                        .sum = self.value.sum,
                        .count = self.value.count,
                        .min = self.value.min,
                        .max = self.value.max,
                    },
                    else => self.value,
                },
                .attributes = try Attributes.with(self.attributes).dupe(allocator),
            };
        }
    };
}

/// Times used to report temporal aggregation.
/// Start time is used to indicate the continuation of previous measurements,
/// while time is used to indicate the moment the measurement is collected from a reader.
pub const Timestamps = struct {
    /// Referred to as "TimeUnixNano" in the OTel spec: the time when the measurement was collected.
    time_ns: u64,
    /// Referred to as "StartTimeUnixNano" in the OTel spec: an optional indication of unbroken time series.
    start_time_ns: ?u64 = null,
};

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

test "datapoint deepCopy" {
    const allocator = std.testing.allocator;
    const val: []const u8 = "name";
    var m = try DataPoint(u32).new(allocator, 42, .{ "anykey", val });
    defer m.deinit(allocator);

    var copy = try m.deepCopy(allocator);
    defer copy.deinit(allocator);

    try std.testing.expect(copy.value == 42);
    try std.testing.expectEqualSlices(Attribute, copy.attributes.?, m.attributes.?);
}

/// A union of measurements with either integer or double values.
/// This is used to represent the data collected by a meter.
pub const MeasurementsData = union(enum) {
    int: []DataPoint(i64),
    double: []DataPoint(f64),
    histogram: []DataPoint(HistogramDataPoint),

    /// Returns true if there are no datapoints.
    pub fn isEmpty(self: MeasurementsData) bool {
        switch (self) {
            inline else => |list| return list.len == 0,
        }
    }

    pub fn deinit(self: *MeasurementsData, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |list| {
                for (list) |*dp| dp.deinit(allocator);
                allocator.free(list);
            },
        }
    }

    /// Create a single entity from 2 distinct measurements data.
    /// If the active tags differ between the two, a panic will occur.
    /// Caller owns the memory.
    pub fn join(self: *MeasurementsData, other: MeasurementsData, allocator: std.mem.Allocator) !void {
        switch (self.*) {
            .int => |list| self.int = try mergeDataPoints(i64, list, other.int, allocator),
            .double => |list| self.double = try mergeDataPoints(f64, list, other.double, allocator),
            .histogram => |list| self.histogram = try mergeDataPoints(HistogramDataPoint, list, other.histogram, allocator),
        }
    }

    fn mergeDataPoints(comptime T: type, dp1: []DataPoint(T), dp2: []DataPoint(T), allocator: std.mem.Allocator) ![]DataPoint(T) {
        defer allocator.free(dp1);
        defer allocator.free(dp2);

        var ret = try allocator.alloc(DataPoint(T), dp1.len + dp2.len);
        for (dp1, 0..) |point, i| {
            ret[i] = point;
        }
        for (dp2, dp1.len..) |point, h| {
            ret[h] = point;
        }
        return ret;
    }

    /// Returns a new MeasurementsData with deduplicated data points based on their attributes.
    /// When attributes coincide with an existing data point, the older is discarded.
    pub fn dedupByAttributes(self: *MeasurementsData, allocator: std.mem.Allocator) !void {
        if (self.isEmpty()) return;
        return switch (self.*) {
            .int => |list| self.int = try pruneByAttributes(i64, list, allocator),
            .double => |list| self.double = try pruneByAttributes(f64, list, allocator),
            .histogram => |list| self.histogram = try pruneByAttributes(HistogramDataPoint, list, allocator),
        };
    }

    fn pruneByAttributes(comptime T: type, dp: []DataPoint(T), allocator: std.mem.Allocator) ![]DataPoint(T) {
        defer allocator.free(dp);

        var seen = std.HashMap(
            Attributes,
            DataPoint(T),
            Attributes.HashContext,
            std.hash_map.default_max_load_percentage,
        ).init(allocator);
        defer seen.deinit();

        for (dp) |point| {
            const gop = try seen.getOrPut(Attributes.with(point.attributes));
            if (gop.found_existing) {
                // we need to free the memory for the duplicate data point before replacing it.
                gop.value_ptr.deinit(allocator);
            }
            gop.value_ptr.* = point;
        }
        var ret = try std.ArrayList(DataPoint(T)).initCapacity(allocator, seen.count());
        var i = seen.valueIterator();
        while (i.next()) |entry| {
            try ret.append(entry.*);
        }

        return try ret.toOwnedSlice();
    }
};

test "MeasurementsData.isEmpty" {
    var m = MeasurementsData{ .int = &.{} };
    try std.testing.expect(m.isEmpty());

    m = MeasurementsData{ .double = &.{} };
    try std.testing.expect(m.isEmpty());
}

test "MeasurementsData.join" {
    const allocator = std.testing.allocator;

    var dp1 = try allocator.alloc(DataPoint(i64), 1);
    var dp2 = try allocator.alloc(DataPoint(i64), 1);

    dp1[0] = try DataPoint(i64).new(allocator, 1, .{});
    dp2[0] = try DataPoint(i64).new(allocator, 2, .{});

    var m1 = MeasurementsData{ .int = dp1 };
    const m2 = MeasurementsData{ .int = dp2 };

    try m1.join(m2, allocator);
    defer allocator.free(m1.int);
    defer for (m1.int) |*dp| dp.deinit(allocator);

    try std.testing.expect(m1.int.len == 2);
    try std.testing.expect(m1.int[0].value == 1);
    try std.testing.expect(m1.int[1].value == 2);
}

test "MeasurementsData.dedupByAttributes" {
    const allocator = std.testing.allocator;

    var dp = try allocator.alloc(DataPoint(i64), 4);

    const val1: []const u8 = "value1";
    const val2: []const u8 = "value2";

    dp[0] = try DataPoint(i64).new(allocator, 1, .{ "key", val1 });
    dp[1] = try DataPoint(i64).new(allocator, 2, .{ "key", val2 });
    dp[2] = try DataPoint(i64).new(allocator, 3, .{ "key", val1 });
    dp[3] = try DataPoint(i64).new(allocator, 4, .{ "key", val1, "other", val2 });

    var mes = MeasurementsData{ .int = dp };

    try mes.dedupByAttributes(allocator);
    defer allocator.free(mes.int);
    defer for (mes.int) |*point| point.deinit(allocator);

    try std.testing.expectEqual(3, mes.int.len);
    try std.testing.expectEqual(2, mes.int[0].value);
    try std.testing.expectEqual(4, mes.int[1].value);
    try std.testing.expectEqual(3, mes.int[2].value);
}

/// A set of data points with a series of metadata coming from the meter and the instrument.
/// Holds the data collected by a single instrument inside a meter.
pub const Measurements = struct {
    meterName: []const u8,
    meterVersion: ?[]const u8,
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

/// Holds the histogram measurements properties.
// TODO: use this struct when aggregating.
pub const HistogramDataPoint = struct {
    // Sorted by upper_bound, last is +Inf.
    // We need tohave them because after exporting we can't reconstruct them.
    explicit_bounds: []const f64,
    bucket_counts: []u64, // Observations per bucket
    sum: ?f64, // Total sum of observations, might not exist when observations can be negative
    count: u64, // Total number of observations
    min: ?f64 = null, // Optional min value
    max: ?f64 = null, // Optional max value
};
