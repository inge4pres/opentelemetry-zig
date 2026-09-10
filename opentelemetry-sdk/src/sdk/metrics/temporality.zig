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
const HistogramDataPoint = @import("../../api/metrics/measurement.zig").HistogramDataPoint;
const view = @import("view.zig");

const TemporalAggregator = @This();

pub const TemporalAggregationError = error{
    MissingTimestampTimeUnixNano,
    MissingTimestampStartTimeUnixNano,
};

/// A representatio of a data point enriched with all the metadata from the instrument and meter hosting it.
pub const ScopedDataPoint = struct {
    scope: InstrumentationScope,
    instrument_options: sdk_instrument.InstrumentOptions,
    instrument_kind: Kind,
    datapoint_attributes: ?[]Attribute,

    pub fn eql(a: ScopedDataPoint, b: ScopedDataPoint) bool {
        const ctx = InstrumentationScope.HashContext{};
        if (!ctx.eql(a.scope, b.scope)) return false;
        if (!std.mem.eql(u8, a.instrument_options.name, b.instrument_options.name)) return false;
        if (!std.mem.eql(u8, a.instrument_options.unit orelse "", b.instrument_options.unit orelse "")) return false;
        if (!std.mem.eql(u8, a.instrument_options.description orelse "", b.instrument_options.description orelse "")) return false;
        if (a.instrument_kind != b.instrument_kind) return false;

        const attrs_context = Attributes.HashContext{};
        return attrs_context.eql(Attributes.with(a.datapoint_attributes), Attributes.with(b.datapoint_attributes));
    }
};

/// Implements the hashing functions needed to store the scoped data points in a hash map.
pub const HashContext = struct {
    pub fn hash(_: HashContext, key: ScopedDataPoint) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.instrument_options.name);
        const unit = key.instrument_options.unit orelse "";
        std.hash.autoHash(&h, unit.len);
        h.update(unit);
        h.update(key.instrument_options.description orelse "");
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
histograms: std.HashMap(ScopedDataPoint, DataPoint(HistogramDataPoint), HashContext, std.hash_map.default_max_load_percentage),

pub fn init(allocator: std.mem.Allocator) !*TemporalAggregator {
    const this = try allocator.create(TemporalAggregator);
    this.* = .{
        .memory = allocator,
        .ints = std.HashMap(ScopedDataPoint, DataPoint(i64), HashContext, std.hash_map.default_max_load_percentage).init(allocator),
        .doubles = std.HashMap(ScopedDataPoint, DataPoint(f64), HashContext, std.hash_map.default_max_load_percentage).init(allocator),
        .histograms = std.HashMap(ScopedDataPoint, DataPoint(HistogramDataPoint), HashContext, std.hash_map.default_max_load_percentage).init(allocator),
    };
    return this;
}

pub fn deinit(self: *TemporalAggregator) void {
    var int_keys = self.ints.keyIterator();
    while (int_keys.next()) |key| {
        if (key.datapoint_attributes) |attrs| self.memory.free(attrs);
    }
    var double_keys = self.doubles.keyIterator();
    while (double_keys.next()) |key| {
        if (key.datapoint_attributes) |attrs| self.memory.free(attrs);
    }
    var histogram_entries = self.histograms.iterator();
    while (histogram_entries.next()) |entry| {
        if (entry.key_ptr.datapoint_attributes) |attrs| {
            self.memory.free(attrs);
        }
        entry.value_ptr.deinit(self.memory);
    }
    self.ints.deinit();
    self.doubles.deinit();
    self.histograms.deinit();
    self.memory.destroy(self);
}

fn processCumulativeDataPoints(
    comptime T: type,
    map: *std.HashMap(ScopedDataPoint, DataPoint(T), HashContext, std.hash_map.default_max_load_percentage),
    measurements: *Measurements,
    datapoints: [*]DataPoint(T),
    array_len: usize,
) !void {
    // Gauges use LastValue semantics: even under cumulative temporality they must
    // report the latest observation, not a running total.
    const keep_last_value = switch (measurements.instrumentKind) {
        .Gauge, .ObservableGauge => true,
        else => false,
    };
    for (0..array_len) |idx| {
        var dp = &datapoints[idx];
        const identity = ScopedDataPoint{
            .scope = measurements.scope,
            .instrument_options = measurements.instrumentOptions,
            .instrument_kind = measurements.instrumentKind,
            .datapoint_attributes = dp.attributes,
        };

        const incoming_ts = dp.timestamps orelse return TemporalAggregationError.MissingTimestampTimeUnixNano;
        const dp_time = incoming_ts.time_ns;
        const dp_start_time = incoming_ts.start_time_ns orelse dp_time;

        const gop = try map.getOrPut(identity);
        if (gop.found_existing) {
            const existing_ts = gop.value_ptr.timestamps orelse return TemporalAggregationError.MissingTimestampStartTimeUnixNano;
            switch (T) {
                HistogramDataPoint => {
                    const stored = &gop.value_ptr.value;
                    stored.count = try std.math.add(u64, stored.count, dp.value.count);

                    stored.sum = if (stored.sum != null and dp.value.sum != null)
                        stored.sum.? + dp.value.sum.?
                    else
                        null;

                    stored.min = if (stored.min != null and dp.value.min != null)
                        @min(stored.min.?, dp.value.min.?)
                    else
                        null;

                    stored.max = if (stored.max != null and dp.value.max != null)
                        @max(stored.max.?, dp.value.max.?)
                    else
                        null;

                    for (stored.bucket_counts, dp.value.bucket_counts) |*stored_count, current_count| {
                        stored_count.* = try std.math.add(u64, stored_count.*, current_count);
                    }
                },
                i64, f64 => {
                    gop.value_ptr.value = if (keep_last_value) dp.value else gop.value_ptr.value + dp.value;
                },
                else => @compileError("unsupported cumulative data point type"),
            }
            gop.value_ptr.timestamps = .{ .start_time_ns = existing_ts.start_time_ns, .time_ns = dp_time };
        } else {
            errdefer _ = map.remove(identity);

            // The key owns the attribute slice so it survives output deinitialization.
            const attrs = try Attributes.with(dp.attributes).dupe(map.allocator);
            errdefer {
                if (attrs) |a| map.allocator.free(a);
            }

            const stored_value = switch (T) {
                HistogramDataPoint => blk: {
                    var value = dp.value;
                    value.bucket_counts = try map.allocator.dupe(u64, dp.value.bucket_counts);
                    break :blk value;
                },
                i64, f64 => dp.value,
                else => @compileError("unsupported cumulative data point type"),
            };

            gop.key_ptr.datapoint_attributes = attrs;
            gop.value_ptr.* = .{
                .value = stored_value,
                .attributes = null,
                .timestamps = .{
                    .start_time_ns = dp_start_time,
                    .time_ns = dp_time,
                },
            };
        }

        const output_value = switch (T) {
            HistogramDataPoint => blk: {
                // Reuse the output buffer, keeping it separate from the saved state.
                var value = gop.value_ptr.value;
                @memcpy(dp.value.bucket_counts, value.bucket_counts);
                value.bucket_counts = dp.value.bucket_counts;
                break :blk value;
            },
            i64, f64 => gop.value_ptr.value,
            else => @compileError("unsupported cumulative data point type"),
        };

        dp.value = output_value;
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
            .instrument_options = measurements.instrumentOptions,
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
        } else {
            // The map outlives the measurements: their attributes are owned by the
            // exporter and freed after export, so the key must own its own copy.
            gop.key_ptr.datapoint_attributes = Attributes.with(dp.attributes).dupe(map.allocator) catch |err| {
                _ = map.remove(identity);
                return err;
            };
        }
        dp.timestamps = .{ .start_time_ns = start_time, .time_ns = dp_time };
        // Update map with this latest datapoint
        gop.value_ptr.value = dp.value;
        gop.value_ptr.timestamps = dp.timestamps;
    }
}

/// Apply the selected temporality to data point values and timestamps.
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
                .histogram => |datapoints| try processCumulativeDataPoints(
                    HistogramDataPoint,
                    &self.histograms,
                    measurements,
                    datapoints.ptr,
                    datapoints.len,
                ),
                // TODO: accumulate exponential histograms across collections.
                .exponential_histogram => return,
                .int => |datapoints| try processCumulativeDataPoints(i64, &self.ints, measurements, datapoints.ptr, datapoints.len),
                .double => |datapoints| try processCumulativeDataPoints(f64, &self.doubles, measurements, datapoints.ptr, datapoints.len),
            }
        },
        .Unspecified => return,
    }
}

test "cumulative histogram reuses the output bucket buffer" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    const ta = try TemporalAggregator.init(allocator);
    defer ta.deinit();

    for ([_]f64{ 0.25, 0.5, 0.75 }, 0..) |value, i| {
        var dp = DataPoint(HistogramDataPoint){
            .value = .{
                .count = 1,
                .sum = value,
                .min = value,
                .max = value,
                .explicit_bounds = &.{ 0.3, 0.6 },
                .bucket_counts = try allocator.dupe(u64, &.{ 0, 0, 0 }),
            },
            .timestamps = .{ .time_ns = (i + 1) * 100 },
        };
        defer dp.deinit(allocator);
        dp.value.bucket_counts[i] = 1;
        var measurements = Measurements{
            .scope = .{ .name = "test" },
            .instrumentKind = .Histogram,
            .instrumentOptions = .{ .name = "test-histogram" },
            .data = .{ .histogram = (&dp)[0..1] },
        };

        // Updating an existing series needs no new output allocation.
        if (i == 1) failing.fail_index = failing.alloc_index;
        try ta.process(&measurements, view.TemporalityCumulative);
        failing.fail_index = std.math.maxInt(usize);

        if (i == 2) {
            try std.testing.expectEqual(3, dp.value.count);
            try std.testing.expectEqual(1.5, dp.value.sum.?);
            try std.testing.expectEqualSlices(u64, &.{ 1, 1, 1 }, dp.value.bucket_counts);
        }
    }
}

test "cumulative histogram leaves state unchanged on count overflow" {
    const allocator = std.testing.allocator;
    const ta = try TemporalAggregator.init(allocator);
    defer ta.deinit();
    var first = DataPoint(HistogramDataPoint){
        .value = .{
            .count = std.math.maxInt(u64),
            .sum = 0,
            .min = 0,
            .max = 0,
            .explicit_bounds = &.{},
            .bucket_counts = try allocator.dupe(u64, &.{std.math.maxInt(u64)}),
        },
        .timestamps = .{ .time_ns = 100 },
    };
    defer first.deinit(allocator);
    var measurements = Measurements{
        .scope = .{ .name = "test" },
        .instrumentKind = .Histogram,
        .instrumentOptions = .{ .name = "test-histogram" },
        .data = .{ .histogram = (&first)[0..1] },
    };
    try ta.process(&measurements, view.TemporalityCumulative);

    var second = first;
    second.value = .{
        .count = 1,
        .sum = 0.5,
        .min = 0.5,
        .max = 0.5,
        .explicit_bounds = &.{},
        .bucket_counts = try allocator.dupe(u64, &.{1}),
    };
    second.timestamps = .{ .time_ns = 200 };
    defer second.deinit(allocator);
    measurements.data = .{ .histogram = (&second)[0..1] };
    try std.testing.expectError(error.Overflow, ta.process(&measurements, view.TemporalityCumulative));
    var entries = ta.histograms.valueIterator();
    try std.testing.expectEqualDeep(first, entries.next().?.*);
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

test "temporal aggregator cumulative gauge keeps last value instead of summing" {
    const allocator = std.testing.allocator;
    const ta = try TemporalAggregator.init(allocator);
    defer ta.deinit();

    const values = [_]i64{ 10, 20, 3, 4 };
    const data_points = try allocator.alloc(DataPoint(i64), 4);
    defer {
        for (data_points) |*dp| dp.deinit(allocator);
        allocator.free(data_points);
    }

    for (0..4) |i| {
        data_points[i] = try DataPoint(i64).new(allocator, values[i], .{});
        data_points[i].timestamps = .{ .time_ns = @intCast(i) };
    }

    var m1 = Measurements{
        .data = .{ .int = data_points[0..2] },
        .scope = .{ .name = "test" },
        .instrumentKind = .Gauge,
        .instrumentOptions = .{ .name = "test" },
    };
    try ta.process(&m1, view.TemporalityCumulative);

    var m2 = Measurements{
        .data = .{ .int = data_points[2..] },
        .scope = .{ .name = "test" },
        .instrumentKind = .Gauge,
        .instrumentOptions = .{ .name = "test" },
    };
    try ta.process(&m2, view.TemporalityCumulative);

    // The second cycle reports its own values, not the running total across cycles.
    // Start time still tracks the first observation for the series.
    try std.testing.expectEqual(3, m2.data.int[0].value);
    try std.testing.expectEqual(0, m2.data.int[0].timestamps.?.start_time_ns);
    try std.testing.expectEqual(2, m2.data.int[0].timestamps.?.time_ns);

    try std.testing.expectEqual(4, m2.data.int[1].value);
    try std.testing.expectEqual(0, m2.data.int[1].timestamps.?.start_time_ns);
    try std.testing.expectEqual(3, m2.data.int[1].timestamps.?.time_ns);
}

test "temporal aggregator cumulative gauge keeps a separate last value per attribute set" {
    const allocator = std.testing.allocator;
    const ta = try TemporalAggregator.init(allocator);
    defer ta.deinit();

    // Three distinct attribute sets, each updated once per cycle. The values are
    // chosen so that any cross-contamination between series (collapsing all
    // attributes into one, or leaking a neighbour's value) would be detectable.
    const route_a: []const u8 = "/a";
    const route_b: []const u8 = "/b";
    const route_c: []const u8 = "/c";
    const routes = [_][]const u8{ route_a, route_b, route_c, route_a, route_b, route_c };
    const values = [_]i64{ 1, 2, 3, 10, 20, 30 };

    const data_points = try allocator.alloc(DataPoint(i64), 6);
    defer {
        for (data_points) |*dp| dp.deinit(allocator);
        allocator.free(data_points);
    }
    for (0..6) |i| {
        data_points[i] = try DataPoint(i64).new(allocator, values[i], .{ "route", routes[i] });
        data_points[i].timestamps = .{ .time_ns = @intCast(i) };
    }

    var m1 = Measurements{
        .data = .{ .int = data_points[0..3] },
        .scope = .{ .name = "test" },
        .instrumentKind = .Gauge,
        .instrumentOptions = .{ .name = "test" },
    };
    try ta.process(&m1, view.TemporalityCumulative);

    var m2 = Measurements{
        .data = .{ .int = data_points[3..6] },
        .scope = .{ .name = "test" },
        .instrumentKind = .Gauge,
        .instrumentOptions = .{ .name = "test" },
    };
    try ta.process(&m2, view.TemporalityCumulative);

    try std.testing.expectEqual(10, m2.data.int[0].value); // /a
    try std.testing.expectEqual(20, m2.data.int[1].value); // /b
    try std.testing.expectEqual(30, m2.data.int[2].value); // /c
}
