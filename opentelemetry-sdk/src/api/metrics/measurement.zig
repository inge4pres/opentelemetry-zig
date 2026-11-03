const std = @import("std");

const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const Kind = @import("instrument.zig").Kind;
const InstrumentOptions = @import("instrument.zig").InstrumentOptions;
const ExponentialHistogramDataPoint = @import("../../sdk/metrics/aggregation.zig").ExponentialHistogramDataPoint;
const AggregationType = @import("../../sdk/metrics/view.zig").AggregationType;

const exemplar_sdk = @import("../../sdk/metrics/exemplar.zig");
const Exemplar = exemplar_sdk.Exemplar;

const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

/// A value recorded with an optional set of attributes.
/// It represents a single data point collected from an instrument.
pub fn DataPoint(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        attributes: ?[]Attribute = null,
        attributes_owned: bool = false,
        exemplar_candidate: ?Exemplar = null,
        exemplars: []Exemplar = &.{},
        timestamps: ?Timestamps = null, // Timestamps are filled in when extracting data points from the meter.

        /// Creates a data points with the provided value and attributes,
        /// adding a timestamp with the current time.
        pub fn new(allocator: std.mem.Allocator, value: T, attributes: anytype) std.mem.Allocator.Error!Self {
            return Self{
                .value = value,
                .attributes = try Attributes.from(allocator, attributes),
            };
        }

        /// Capture an eligible measurement before its caller's context changes.
        pub fn captureExemplar(self: *Self, allocator: std.mem.Allocator, filter: exemplar_sdk.ExemplarFilter) !void {
            var candidate = try Exemplar.capture(T, allocator, self.value, self.attributes, filter);
            errdefer if (candidate) |*sample| sample.deinit(allocator);
            if (candidate != null) try self.ownAttributes(allocator);
            if (self.exemplar_candidate) |*previous| previous.deinit(allocator);
            self.exemplar_candidate = candidate;
        }

        pub fn ownAttributes(self: *Self, allocator: std.mem.Allocator) !void {
            const attributes = self.attributes orelse return;
            if (self.attributes_owned) return;
            const owned = try Exemplar.copyAttributes(allocator, attributes);
            allocator.free(attributes);
            self.attributes = owned;
            self.attributes_owned = true;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            switch (T) {
                HistogramDataPoint => allocator.free(self.value.bucket_counts),
                ExponentialHistogramDataPoint => {
                    allocator.free(self.value.positive_bucket_counts);
                    allocator.free(self.value.negative_bucket_counts);
                },
                else => {},
            }
            if (self.attributes) |attributes| {
                if (self.attributes_owned) for (attributes) |attr| {
                    allocator.free(attr.key);
                    if (attr.value == .string) allocator.free(attr.value.string);
                };
                allocator.free(attributes);
            }
            if (self.exemplar_candidate) |*sample| sample.deinit(allocator);
            Exemplar.deinitList(allocator, self.exemplars);
        }

        pub fn deepCopy(self: Self, allocator: std.mem.Allocator) !Self {
            const attr = if (self.attributes) |a|
                if (self.attributes_owned) try Exemplar.copyAttributes(allocator, a) else try allocator.dupe(Attribute, a)
            else
                null;
            errdefer if (attr) |a| {
                if (self.attributes_owned) for (a) |attribute| {
                    allocator.free(attribute.key);
                    if (attribute.value == .string) allocator.free(attribute.value.string);
                };
                allocator.free(a);
            };
            var candidate = if (self.exemplar_candidate) |sample| try sample.deepCopy(allocator) else null;
            errdefer if (candidate) |*sample| sample.deinit(allocator);
            const samples = try exemplar_sdk.copyList(allocator, self.exemplars);
            errdefer Exemplar.deinitList(allocator, samples);
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
                    ExponentialHistogramDataPoint => blk: {
                        const positive_bucket_counts = try allocator.dupe(u64, self.value.positive_bucket_counts);
                        errdefer allocator.free(positive_bucket_counts);
                        const negative_bucket_counts = try allocator.dupe(u64, self.value.negative_bucket_counts);
                        const value = ExponentialHistogramDataPoint{
                            .sum = self.value.sum,
                            .count = self.value.count,
                            .min = self.value.min,
                            .max = self.value.max,
                            .scale = self.value.scale,
                            .zero_count = self.value.zero_count,
                            .positive_offset = self.value.positive_offset,
                            .positive_bucket_counts = positive_bucket_counts,
                            .negative_offset = self.value.negative_offset,
                            .negative_bucket_counts = negative_bucket_counts,
                        };
                        break :blk value;
                    },
                    else => self.value,
                },
                .attributes = attr,
                .attributes_owned = self.attributes_owned,
                .exemplar_candidate = candidate,
                .exemplars = samples,
                .timestamps = self.timestamps,
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
    exponential_histogram: []DataPoint(ExponentialHistogramDataPoint),

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
            .exponential_histogram => |list| self.exponential_histogram = try mergeDataPoints(ExponentialHistogramDataPoint, list, other.exponential_histogram, allocator),
        }
    }

    fn mergeDataPoints(comptime T: type, dp1: []DataPoint(T), dp2: []DataPoint(T), allocator: std.mem.Allocator) ![]DataPoint(T) {
        var ret = try allocator.alloc(DataPoint(T), dp1.len + dp2.len);
        defer allocator.free(dp1);
        defer allocator.free(dp2);
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
            .exponential_histogram => |list| self.exponential_histogram = try pruneByAttributes(ExponentialHistogramDataPoint, list, allocator),
        };
    }

    fn pruneByAttributes(comptime T: type, dp: []DataPoint(T), allocator: std.mem.Allocator) ![]DataPoint(T) {
        var seen = std.HashMap(
            Attributes,
            usize,
            Attributes.HashContext,
            std.hash_map.default_max_load_percentage,
        ).init(allocator);
        defer seen.deinit();
        for (dp, 0..) |point, index| {
            const gop = try seen.getOrPut(Attributes.with(point.attributes));
            gop.value_ptr.* = index;
        }
        const ret = try allocator.alloc(DataPoint(T), seen.count());
        errdefer allocator.free(ret);
        const selected = try allocator.alloc(bool, dp.len);
        defer allocator.free(selected);
        @memset(selected, false);
        var indices = seen.valueIterator();
        var out: usize = 0;
        while (indices.next()) |index| {
            selected[index.*] = true;
            ret[out] = dp[index.*];
            out += 1;
        }
        // Hash keys borrow input attributes until all lookups have finished.
        for (dp, selected) |*point, keep| if (!keep) point.deinit(allocator);
        allocator.free(dp);
        return ret;
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
    scope: InstrumentationScope,

    instrumentKind: Kind,
    instrumentOptions: InstrumentOptions,

    data: MeasurementsData,
    /// Aggregation that produced `data`, null when unknown (e.g. measurements built by hand).
    aggregation: ?AggregationType = null,

    resource: ?[]const Attribute = null,

    /// Numeric data is either a Sum or a LastValue result.
    /// Without a known aggregation, gauges are assumed to be LastValue.
    pub fn isLastValue(self: Measurements) bool {
        if (self.aggregation) |a| return a == .LastValue;
        return switch (self.instrumentKind) {
            .Gauge, .ObservableGauge => true,
            else => false,
        };
    }

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
    // We need to have them because after exporting we can't reconstruct them.
    explicit_bounds: []const f64,
    bucket_counts: []u64, // Observations per bucket
    sum: ?f64, // Total sum of observations, might not exist when observations can be negative
    count: u64, // Total number of observations
    min: ?f64 = null, // Optional min value
    max: ?f64 = null, // Optional max value
};

test "exemplar datapoint copies own their samples" {
    const allocator = std.testing.allocator;
    const attrs = [_]Attribute{.{ .key = "request", .value = .{ .string = "first" } }};
    var point = DataPoint(i64){ .value = 7, .exemplar_candidate = (try Exemplar.capture(i64, allocator, 7, &attrs, .always_on)).? };
    point.exemplars = try allocator.alloc(Exemplar, 1);
    point.exemplars[0] = try point.exemplar_candidate.?.deepCopy(allocator);
    var copy = try point.deepCopy(allocator);
    defer copy.deinit(allocator);
    point.deinit(allocator);
    try std.testing.expectEqualStrings("first", copy.exemplar_candidate.?.filtered_attributes[0].value.string);
    try std.testing.expectEqualStrings("first", copy.exemplars[0].filtered_attributes[0].value.string);
}

test "exemplar datapoint copying cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exemplarPointCopyFailure, .{});
}

fn exemplarPointCopyFailure(allocator: std.mem.Allocator) !void {
    var point = DataPoint(i64){ .value = 7 };
    defer point.deinit(allocator);
    point.exemplars = try allocator.alloc(Exemplar, 1);
    point.exemplars[0] = .{ .value = .{ .int = 7 }, .time_ns = 123 };
    const attrs = [_]Attribute{.{ .key = "request", .value = .{ .string = "first" } }};
    point.exemplar_candidate = (try Exemplar.capture(i64, allocator, 7, &attrs, .always_on)).?;
    var copy = try point.deepCopy(allocator);
    defer copy.deinit(allocator);
}

test "exemplar capture replaces owned snapshots without leaks" {
    inline for (.{ exemplar_sdk.ExemplarFilter.always_on, exemplar_sdk.ExemplarFilter.always_off }) |filter|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, recaptureExemplarFailure, .{filter});
}

fn recaptureExemplarFailure(allocator: std.mem.Allocator, filter: exemplar_sdk.ExemplarFilter) !void {
    var point = try DataPoint(i64).new(allocator, 7, .{ "request", @as([]const u8, "first") });
    defer point.deinit(allocator);
    try point.captureExemplar(allocator, .always_on);
    try point.captureExemplar(allocator, filter);
    try std.testing.expectEqual(filter == .always_on, point.exemplar_candidate != null);
}
