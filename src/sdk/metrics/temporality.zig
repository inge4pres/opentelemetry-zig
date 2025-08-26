//! This module implements temporal aggregation for metrics.
//! The feature developed here is mostly described in the[temporality section](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#temporality).

const std = @import("std");
const sdk_instrument = @import("../../api/metrics/instrument.zig");
const Instrument = sdk_instrument.Instrument;
const Kind = sdk_instrument.Kind;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const DataPoint = @import("../../api/metrics/measurement.zig").DataPoint;
const Measurements = @import("../../api/metrics/measurement.zig").Measurements;
const view = @import("view.zig");

const TemporalAggregator = @This();

pub const TemporalAggregationError = error{
    MissingTimestampTimeUnixNano,
    MissingTimestampStartTimeUnixNano,
};

/// A representatio of a data point enriched with all the metadata from the instrument and meter hosting it.
pub const ScopedDataPoint = struct {
    scope: InstrumentationScope,
    instrument_name: []const u8,
    instrument_kind: Kind,
    datapoint_attributes: ?[]Attribute,

    pub fn eql(a: ScopedDataPoint, b: ScopedDataPoint) bool {
        const ctx = InstrumentationScope.HashContext{};
        if (!ctx.eql(a.scope, b.scope)) return false;
        if (!std.mem.eql(u8, a.instrument_name, b.instrument_name)) return false;
        if (a.instrument_kind != b.instrument_kind) return false;

        const attrs_context = Attributes.HashContext{};
        return attrs_context.eql(Attributes.with(a.datapoint_attributes), Attributes.with(b.datapoint_attributes));
    }
};

/// Implements the hashing functions needed to store the scoped data points in a hash map.
pub const HashContext = struct {
    pub fn hash(_: HashContext, key: ScopedDataPoint) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.instrument_name);
        std.hash.autoHash(&h, key.instrument_kind);

        const instrument_hash = InstrumentationScope.HashContext{};
        std.hash.autoHash(&h, instrument_hash.hash(key.scope));

        const attributes_hash = Attributes.HashContext{};
        std.hash.autoHash(&h, attributes_hash.hash(Attributes.with(key.datapoint_attributes)));

        return h.final();
    }

    pub fn eql(_: HashContext, a: ScopedDataPoint, b: ScopedDataPoint) bool {
        return a.eql(b);
    }
};

memory: std.mem.Allocator,
ints: std.HashMap(ScopedDataPoint, DataPoint(i64), HashContext, std.hash_map.default_max_load_percentage),
doubles: std.HashMap(ScopedDataPoint, DataPoint(f64), HashContext, std.hash_map.default_max_load_percentage),

pub fn init(allocator: std.mem.Allocator) !*TemporalAggregator {
    const this = try allocator.create(TemporalAggregator);
    this.* = .{
        .memory = allocator,
        .ints = std.HashMap(ScopedDataPoint, DataPoint(i64), HashContext, std.hash_map.default_max_load_percentage).init(allocator),
        .doubles = std.HashMap(ScopedDataPoint, DataPoint(f64), HashContext, std.hash_map.default_max_load_percentage).init(allocator),
    };
    return this;
}

pub fn deinit(self: *TemporalAggregator) void {
    self.ints.deinit();
    self.doubles.deinit();
    self.memory.destroy(self);
}

fn processCumulativeDataPoints(
    comptime T: type,
    map: *std.HashMap(ScopedDataPoint, DataPoint(T), HashContext, std.hash_map.default_max_load_percentage),
    measurements: *Measurements,
    datapoints: [*]DataPoint(T),
    array_len: usize,
) !void {
    for (0..array_len) |idx| {
        var dp = &datapoints[idx];
        const identity = ScopedDataPoint{
            .scope = measurements.scope,
            .instrument_name = measurements.instrumentOptions.name,
            .instrument_kind = measurements.instrumentKind,
            .datapoint_attributes = dp.attributes,
        };

        const incoming_ts = dp.timestamps orelse return TemporalAggregationError.MissingTimestampTimeUnixNano;
        const dp_time = incoming_ts.time_ns;
        const dp_start_time = incoming_ts.start_time_ns orelse dp_time;

        const gop = try map.getOrPut(identity);
        if (gop.found_existing) {
            const existing_start_time = if (gop.value_ptr.timestamps) |existing_time| existing_time.start_time_ns else return TemporalAggregationError.MissingTimestampStartTimeUnixNano;
            gop.value_ptr.timestamps = .{ .start_time_ns = existing_start_time, .time_ns = dp_time };
            gop.value_ptr.value += dp.value;
        } else {
            gop.value_ptr.value = dp.value;
            gop.value_ptr.timestamps = .{ .start_time_ns = dp_start_time, .time_ns = dp_time };
        }
        dp.value = gop.value_ptr.value;
        dp.timestamps = gop.value_ptr.timestamps;
    }
}

fn processDeltaDataPoints(
    comptime T: type,
    map: *std.HashMap(ScopedDataPoint, DataPoint(T), HashContext, std.hash_map.default_max_load_percentage),
    measurements: *Measurements,
    datapoints: [*]DataPoint(T),
    array_len: usize,
) !void {
    for (0..array_len) |idx| {
        var dp = &datapoints[idx];
        const identity = ScopedDataPoint{
            .scope = measurements.scope,
            .instrument_name = measurements.instrumentOptions.name,
            .instrument_kind = measurements.instrumentKind,
            .datapoint_attributes = dp.attributes,
        };

        const incoming_ts = dp.timestamps orelse return TemporalAggregationError.MissingTimestampTimeUnixNano;
        const dp_time = incoming_ts.time_ns;
        var start_time: u64 = 0;
        const gop = try map.getOrPut(identity);
        if (gop.found_existing) {
            if (gop.value_ptr.timestamps) |existing_time| {
                start_time = existing_time.time_ns;
            }
        }
        dp.timestamps = .{ .start_time_ns = start_time, .time_ns = dp_time };
        // Update map with this latest datapoint
        gop.value_ptr.value = dp.value;
        gop.value_ptr.timestamps = dp.timestamps;
    }
}

/// Extract the temporality for each unique measurement and applies the proper timestamps to the data points.
pub fn process(self: *TemporalAggregator, measurements: *Measurements, temporality: view.TemporalitySelector) !void {
    switch (temporality(measurements.instrumentKind)) {
        .Delta => {
            switch (measurements.data) {
                // Histogram data points are impossible to implement as .Delta at the moment, because the aggregation is computed on raw data points.
                // TODO either return an error or implement the .Delta temporality for histogram data points.
                .histogram, .exponential_histogram => return,
                .int => |datapoints| try processDeltaDataPoints(i64, &self.ints, measurements, datapoints.ptr, datapoints.len),
                .double => |datapoints| try processDeltaDataPoints(f64, &self.doubles, measurements, datapoints.ptr, datapoints.len),
            }
        },
        .Cumulative => {
            switch (measurements.data) {
                // TODO update here when the histogram attributes are implemented as an aggregation from raw data points rather than pre-computing them.
                .histogram, .exponential_histogram => return,
                .int => |datapoints| try processCumulativeDataPoints(i64, &self.ints, measurements, datapoints.ptr, datapoints.len),
                .double => |datapoints| try processCumulativeDataPoints(f64, &self.doubles, measurements, datapoints.ptr, datapoints.len),
            }
        },
        .Unspecified => return,
    }
}

test "temporal aggregator process cumulative without timestamps returns error" {
    const allocator = std.testing.allocator;
    const ta = try TemporalAggregator.init(allocator);
    defer ta.deinit();

    const data_points = try allocator.alloc(DataPoint(i64), 4);
    defer {
        for (data_points) |*dp| dp.deinit(allocator);
        allocator.free(data_points);
    }

    for (0..4) |i| {
        data_points[i] = try DataPoint(i64).new(allocator, @intCast(i), .{ "key", true, "secondkey", @as(u64, @mod(i, 2)) });
    }

    var m1 = Measurements{
        .data = .{ .int = data_points },
        .scope = .{
            .name = "test",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "test" },
    };

    const result = ta.process(&m1, view.TemporalityCumulative);
    try std.testing.expectError(TemporalAggregationError.MissingTimestampTimeUnixNano, result);
}

test "temporal aggregator process delta temporality with timestamps" {
    const allocator = std.testing.allocator;
    const ta = try TemporalAggregator.init(allocator);
    defer ta.deinit();

    const data_points = try allocator.alloc(DataPoint(i64), 4);
    defer {
        for (data_points) |*dp| dp.deinit(allocator);
        allocator.free(data_points);
    }

    // Simulate two rounds of measurements with paired attributes.
    for (0..4) |i| {
        data_points[i] = try DataPoint(i64).new(allocator, @intCast(i), .{ "key", true, "secondkey", @as(u64, @mod(i, 2)) });
        data_points[i].timestamps = .{ .time_ns = @intCast(i + 100) };
    }

    var m1 = Measurements{
        .data = .{ .int = data_points[0..2] },
        .scope = .{
            .name = "test",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "test" },
    };
    var m2 = Measurements{
        .data = .{ .int = data_points[2..] },
        .scope = .{
            .name = "test",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "test" },
    };

    try ta.process(&m1, view.TemporalityDelta);
    // First batch: start_time_ns == 0 for each point
    try std.testing.expectEqual(@as(u64, 0), m1.data.int[0].timestamps.?.start_time_ns);
    try std.testing.expectEqual(100, m1.data.int[0].timestamps.?.time_ns);
    try std.testing.expectEqual(@as(u64, 0), m1.data.int[1].timestamps.?.start_time_ns);
    try std.testing.expectEqual(101, m1.data.int[1].timestamps.?.time_ns);

    try ta.process(&m2, view.TemporalityDelta);
    // Second batch: start_time_ns == previous time_ns for each identity
    try std.testing.expectEqual(100, m2.data.int[0].timestamps.?.start_time_ns);
    try std.testing.expectEqual(102, m2.data.int[0].timestamps.?.time_ns);
    try std.testing.expectEqual(101, m2.data.int[1].timestamps.?.start_time_ns);
    try std.testing.expectEqual(103, m2.data.int[1].timestamps.?.time_ns);
}

test "temporal aggregator process cumulative temporality with timestamps" {
    const allocator = std.testing.allocator;
    const ta = try TemporalAggregator.init(allocator);
    defer ta.deinit();

    const data_points = try allocator.alloc(DataPoint(i64), 4);
    defer {
        for (data_points) |*dp| dp.deinit(allocator);
        allocator.free(data_points);
    }

    // we will form 2 test measurements, each with 2 data points.
    // Data points will have paired attributes (true, 0) and (true, 1) to simulate aggregation.
    // Timestamps are progressiveto see if we are setting the right start time.
    for (0..4) |i| {
        data_points[i] = try DataPoint(i64).new(allocator, @intCast(i), .{ "key", true, "secondkey", @as(u64, @mod(i, 2)) });
        // Simulate what AggregateMetrics does, adding collection timestamps
        data_points[i].timestamps = .{ .time_ns = @intCast(i) };
    }

    var m1 = Measurements{
        .data = .{ .int = data_points[0..2] },
        .scope = .{
            .name = "test",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "test" },
    };
    var m2 = Measurements{
        .data = .{ .int = data_points[2..] },
        .scope = .{
            .name = "test",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "test" },
    };

    try ta.process(&m1, view.TemporalityCumulative);
    try ta.process(&m2, view.TemporalityCumulative);

    try std.testing.expectEqual(2, m2.data.int[0].value);
    try std.testing.expectEqual(0, m2.data.int[0].timestamps.?.start_time_ns);
    try std.testing.expectEqual(2, m2.data.int[0].timestamps.?.time_ns);
    try std.testing.expectEqual(4, m2.data.int[1].value);
    try std.testing.expectEqual(1, m2.data.int[1].timestamps.?.start_time_ns);
    try std.testing.expectEqual(3, m2.data.int[1].timestamps.?.time_ns);
}
