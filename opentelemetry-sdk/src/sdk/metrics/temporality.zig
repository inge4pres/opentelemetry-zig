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
const ExponentialHistogramDataPoint = @import("../../sdk/metrics/aggregation.zig").ExponentialHistogramDataPoint;
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
exponential_histogram: std.HashMap(ScopedDataPoint, DataPoint(ExponentialHistogramDataPoint), HashContext, std.hash_map.default_max_load_percentage),

pub fn init(allocator: std.mem.Allocator) !*TemporalAggregator {
    const this = try allocator.create(TemporalAggregator);
    this.* = .{
        .memory = allocator,
        .ints = std.HashMap(ScopedDataPoint, DataPoint(i64), HashContext, std.hash_map.default_max_load_percentage).init(allocator),
        .doubles = std.HashMap(ScopedDataPoint, DataPoint(f64), HashContext, std.hash_map.default_max_load_percentage).init(allocator),
        .histograms = std.HashMap(ScopedDataPoint, DataPoint(HistogramDataPoint), HashContext, std.hash_map.default_max_load_percentage).init(allocator),
        .exponential_histogram = std.HashMap(ScopedDataPoint, DataPoint(ExponentialHistogramDataPoint), HashContext, std.hash_map.default_max_load_percentage).init(allocator),
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
    var exponential_histogram_entries = self.exponential_histogram.iterator();
    while (exponential_histogram_entries.next()) |entry| {
        if (entry.key_ptr.datapoint_attributes) |attrs| {
            self.memory.free(attrs);
        }
        entry.value_ptr.deinit(self.memory);
    }
    self.ints.deinit();
    self.doubles.deinit();
    self.histograms.deinit();
    self.exponential_histogram.deinit();
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
                ExponentialHistogramDataPoint => {
                    const stored = &gop.value_ptr.value;
                    const new_count = try std.math.add(u64, stored.count, dp.value.count);
                    const new_zero_count = try std.math.add(u64, stored.zero_count, dp.value.zero_count);

                    if (stored.scale > dp.value.scale) {
                        const new_positive_buckets = try bucketScaleConverter(
                            map.allocator,
                            stored.positive_offset,
                            stored.positive_bucket_counts,
                            stored.scale - dp.value.scale,
                        );
                        errdefer {
                            map.allocator.free(new_positive_buckets.bucket_counts);
                        }

                        const new_negative_buckets = try bucketScaleConverter(
                            map.allocator,
                            stored.negative_offset,
                            stored.negative_bucket_counts,
                            stored.scale - dp.value.scale,
                        );
                        errdefer {
                            map.allocator.free(new_negative_buckets.bucket_counts);
                        }

                        map.allocator.free(stored.positive_bucket_counts);
                        map.allocator.free(stored.negative_bucket_counts);

                        stored.positive_bucket_counts = new_positive_buckets.bucket_counts;
                        stored.negative_bucket_counts = new_negative_buckets.bucket_counts;
                        stored.positive_offset = new_positive_buckets.offset;
                        stored.negative_offset = new_negative_buckets.offset;
                        stored.scale = dp.value.scale;
                    } else if (dp.value.scale > stored.scale) {
                        const new_positive_buckets = try bucketScaleConverter(
                            map.allocator,
                            dp.value.positive_offset,
                            dp.value.positive_bucket_counts,
                            dp.value.scale - stored.scale,
                        );
                        errdefer {
                            map.allocator.free(new_positive_buckets.bucket_counts);
                        }

                        const new_negative_buckets = try bucketScaleConverter(
                            map.allocator,
                            dp.value.negative_offset,
                            dp.value.negative_bucket_counts,
                            dp.value.scale - stored.scale,
                        );
                        errdefer {
                            map.allocator.free(new_negative_buckets.bucket_counts);
                        }

                        map.allocator.free(dp.value.positive_bucket_counts);
                        map.allocator.free(dp.value.negative_bucket_counts);

                        dp.value.positive_bucket_counts = new_positive_buckets.bucket_counts;
                        dp.value.negative_bucket_counts = new_negative_buckets.bucket_counts;
                        dp.value.positive_offset = new_positive_buckets.offset;
                        dp.value.negative_offset = new_negative_buckets.offset;
                        dp.value.scale = stored.scale;
                    }

                    const positive_buckets = try bucketAggregation(
                        map.allocator,
                        stored.positive_offset,
                        stored.positive_bucket_counts,
                        dp.value.positive_offset,
                        dp.value.positive_bucket_counts,
                    );
                    errdefer map.allocator.free(positive_buckets.bucket_counts);

                    const negative_buckets = try bucketAggregation(
                        map.allocator,
                        stored.negative_offset,
                        stored.negative_bucket_counts,
                        dp.value.negative_offset,
                        dp.value.negative_bucket_counts,
                    );
                    errdefer map.allocator.free(negative_buckets.bucket_counts);

                    map.allocator.free(stored.positive_bucket_counts);
                    map.allocator.free(stored.negative_bucket_counts);

                    stored.count = new_count;
                    stored.zero_count = new_zero_count;
                    stored.positive_offset = positive_buckets.offset;
                    stored.negative_offset = negative_buckets.offset;
                    stored.positive_bucket_counts = positive_buckets.bucket_counts;
                    stored.negative_bucket_counts = negative_buckets.bucket_counts;

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
                ExponentialHistogramDataPoint => blk: {
                    var value = dp.value;
                    const stored_positive_bucket_counts = try map.allocator.dupe(u64, dp.value.positive_bucket_counts);
                    errdefer map.allocator.free(stored_positive_bucket_counts);
                    value.positive_bucket_counts = stored_positive_bucket_counts;

                    const stored_negative_bucket_counts = try map.allocator.dupe(u64, dp.value.negative_bucket_counts);
                    errdefer map.allocator.free(stored_negative_bucket_counts);
                    value.negative_bucket_counts = stored_negative_bucket_counts;
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
            ExponentialHistogramDataPoint => blk: {
                var value = gop.value_ptr.value;
                const output_positive_bucket_counts = try map.allocator.dupe(u64, value.positive_bucket_counts);
                errdefer map.allocator.free(output_positive_bucket_counts);
                value.positive_bucket_counts = output_positive_bucket_counts;

                const output_negative_bucket_counts = try map.allocator.dupe(u64, value.negative_bucket_counts);
                errdefer map.allocator.free(output_negative_bucket_counts);
                value.negative_bucket_counts = output_negative_bucket_counts;

                map.allocator.free(dp.value.positive_bucket_counts);
                map.allocator.free(dp.value.negative_bucket_counts);
                break :blk value;
            },
            i64, f64 => gop.value_ptr.value,
            else => @compileError("unsupported cumulative data point type"),
        };

        dp.value = output_value;
        dp.timestamps = gop.value_ptr.timestamps;
    }
}

fn bucketScaleConverter(
    allocator: std.mem.Allocator,
    offset: i32,
    bucket_counts: []const u64,
    scale_delta: i32,
) !struct { offset: i32, bucket_counts: []u64 } {
    const new_offset = std.math.shr(i32, offset, scale_delta);
    const new_bucket_len = if (bucket_counts.len > 0) blk: {
        const last_stored_bucket_number = offset + @as(i32, @intCast(bucket_counts.len - 1));
        const new_last_bucket_number = std.math.shr(i32, last_stored_bucket_number, scale_delta);
        break :blk (new_last_bucket_number - new_offset + 1);
    } else 0;

    const new_bucket_counts = try allocator.alloc(u64, @as(usize, @intCast(new_bucket_len)));
    errdefer {
        allocator.free(new_bucket_counts);
    }
    @memset(new_bucket_counts, 0);

    for (bucket_counts, 0..) |count, i| {
        const bucket_number = offset + @as(i32, @intCast(i));
        const new_bucket_number = std.math.shr(i32, bucket_number, scale_delta);
        const new_index = @as(usize, @intCast(new_bucket_number - new_offset));
        new_bucket_counts[new_index] = try std.math.add(u64, new_bucket_counts[new_index], count);
    }

    return .{ .offset = new_offset, .bucket_counts = new_bucket_counts };
}

fn bucketAggregation(
    allocator: std.mem.Allocator,
    stored_offset: i32,
    stored_bucket_counts: []const u64,
    incoming_offset: i32,
    incoming_bucket_counts: []const u64,
) !struct { offset: i32, bucket_counts: []u64 } {
    const new_offset = if (stored_bucket_counts.len != 0 and incoming_bucket_counts.len != 0)
        @min(stored_offset, incoming_offset)
    else if (stored_bucket_counts.len != 0)
        stored_offset
    else if (incoming_bucket_counts.len != 0)
        incoming_offset
    else
        0;

    const new_bucket_len = if (stored_bucket_counts.len != 0 and incoming_bucket_counts.len != 0) blk: {
        const stored_last_number = stored_offset + @as(i32, @intCast(stored_bucket_counts.len - 1));
        const incoming_last_number = incoming_offset + @as(i32, @intCast(incoming_bucket_counts.len - 1));
        const max_number = @max(stored_last_number, incoming_last_number);
        break :blk @as(usize, @intCast(max_number - new_offset + 1));
    } else if (stored_bucket_counts.len != 0)
        stored_bucket_counts.len
    else if (incoming_bucket_counts.len != 0)
        incoming_bucket_counts.len
    else
        0;

    const new_bucket_counts = try allocator.alloc(u64, new_bucket_len);
    errdefer allocator.free(new_bucket_counts);
    @memset(new_bucket_counts, 0);

    for ([_]struct { offset: i32, bucket_counts: []const u64 }{
        .{
            .offset = stored_offset,
            .bucket_counts = stored_bucket_counts,
        },
        .{
            .offset = incoming_offset,
            .bucket_counts = incoming_bucket_counts,
        },
    }) |buckets| {
        for (buckets.bucket_counts, 0..) |count, i| {
            const new_bucket_number = buckets.offset + @as(i32, @intCast(i));
            const new_index = @as(usize, @intCast(new_bucket_number - new_offset));
            new_bucket_counts[new_index] = try std.math.add(u64, new_bucket_counts[new_index], count);
        }
    }

    return .{ .offset = new_offset, .bucket_counts = new_bucket_counts };
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
                .exponential_histogram => |datapoints| try processCumulativeDataPoints(
                    ExponentialHistogramDataPoint,
                    &self.exponential_histogram,
                    measurements,
                    datapoints.ptr,
                    datapoints.len,
                ),
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

test "cumulative histograms leave state unchanged on count overflow" {
    const allocator = std.testing.allocator;
    inline for (.{ HistogramDataPoint, ExponentialHistogramDataPoint }) |T| {
        const ta = try TemporalAggregator.init(allocator);
        defer ta.deinit();
        var first = DataPoint(T){
            .value = if (T == HistogramDataPoint) .{
                .count = std.math.maxInt(u64),
                .sum = 0,
                .min = 0,
                .max = 0,
                .explicit_bounds = &.{},
                .bucket_counts = try allocator.dupe(u64, &.{std.math.maxInt(u64)}),
            } else .{
                .sum = 0,
                .count = std.math.maxInt(u64),
                .zero_count = std.math.maxInt(u64),
                .min = 0,
                .max = 0,
                .scale = 0,
                .positive_offset = 0,
                .negative_offset = 0,
                .positive_bucket_counts = &.{},
                .negative_bucket_counts = &.{},
            },
            .timestamps = .{ .time_ns = 100 },
        };
        defer first.deinit(allocator);
        var measurements = Measurements{
            .scope = .{ .name = "test" },
            .instrumentKind = .Histogram,
            .instrumentOptions = .{ .name = "test-histogram" },
            .data = if (T == HistogramDataPoint) .{
                .histogram = (&first)[0..1],
            } else .{
                .exponential_histogram = (&first)[0..1],
            },
        };
        try ta.process(&measurements, view.TemporalityCumulative);

        var second = first;
        second.value = if (T == HistogramDataPoint) .{
            .count = 1,
            .sum = 0.5,
            .min = 0.5,
            .max = 0.5,
            .explicit_bounds = &.{},
            .bucket_counts = try allocator.dupe(u64, &.{1}),
        } else .{
            .count = 1,
            .sum = 1.5,
            .min = 1.5,
            .max = 1.5,
            .scale = 0,
            .zero_count = 0,
            .positive_offset = 0,
            .negative_offset = 0,
            .positive_bucket_counts = try allocator.dupe(u64, &.{1}),
            .negative_bucket_counts = &.{},
        };
        second.timestamps = .{ .time_ns = 200 };
        defer second.deinit(allocator);
        measurements.data = if (T == HistogramDataPoint) .{
            .histogram = (&second)[0..1],
        } else .{
            .exponential_histogram = (&second)[0..1],
        };
        try std.testing.expectError(error.Overflow, ta.process(&measurements, view.TemporalityCumulative));
        var entries = if (T == HistogramDataPoint) ta.histograms.valueIterator() else ta.exponential_histogram.valueIterator();
        try std.testing.expectEqualDeep(first, entries.next().?.*);
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

test "cumulative exponential histogram merges buckets at different scales" {
    const allocator = std.testing.allocator;

    for ([_]bool{ false, true }) |reverse_order| {
        const ta = try TemporalAggregator.init(allocator);
        defer ta.deinit();
        var first = DataPoint(ExponentialHistogramDataPoint){
            .value = .{
                .count = 21,
                .sum = null,
                .scale = 2,
                .zero_count = 0,
                .positive_offset = -3,
                .positive_bucket_counts = try allocator.dupe(u64, &.{ 1, 2, 3, 4, 5 }),
                .negative_offset = -1,
                .negative_bucket_counts = try allocator.dupe(u64, &.{ 2, 1, 3 }),
            },
            .timestamps = .{ .time_ns = 100 },
        };
        defer first.deinit(allocator);

        var second = first;
        second.value = .{
            .count = 6,
            .sum = null,
            .scale = 0,
            .zero_count = 0,
            .positive_offset = -1,
            .positive_bucket_counts = try allocator.dupe(u64, &.{ 2, 1 }),
            .negative_offset = -1,
            .negative_bucket_counts = try allocator.dupe(u64, &.{ 1, 2 }),
        };
        second.timestamps = .{ .time_ns = 200 };
        defer second.deinit(allocator);

        if (reverse_order) {
            std.mem.swap(ExponentialHistogramDataPoint, &first.value, &second.value);
        }

        var measurements = Measurements{
            .scope = .{ .name = "test" },
            .instrumentKind = .Histogram,
            .instrumentOptions = .{ .name = "test-exponential-histogram" },
            .data = .{ .exponential_histogram = (&first)[0..1] },
        };
        try ta.process(&measurements, view.TemporalityCumulative);

        measurements.data = .{ .exponential_histogram = (&second)[0..1] };
        try ta.process(&measurements, view.TemporalityCumulative);

        try std.testing.expectEqual(0, second.value.scale);
        try std.testing.expectEqual(27, second.value.count);
        try std.testing.expectEqual(-1, second.value.positive_offset);
        try std.testing.expectEqual(-1, second.value.negative_offset);
        try std.testing.expectEqualSlices(u64, &.{ 8, 10 }, second.value.positive_bucket_counts);
        try std.testing.expectEqualSlices(u64, &.{ 3, 6 }, second.value.negative_bucket_counts);
    }
}

test "cumulative exponential histogram cleans up on allocation failure" {
    inline for (.{ .initial, .stored_finer, .incoming_finer }) |scenario| {
        var failure_offset: usize = 0;
        while (true) : (failure_offset += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const allocator = failing.allocator();
            const ta = try TemporalAggregator.init(allocator);
            defer ta.deinit();

            var first = DataPoint(ExponentialHistogramDataPoint){
                .value = .{
                    .count = 21,
                    .sum = null,
                    .scale = 2,
                    .zero_count = 0,
                    .positive_offset = -3,
                    .positive_bucket_counts = try allocator.dupe(u64, &.{ 1, 2, 3, 4, 5 }),
                    .negative_offset = -1,
                    .negative_bucket_counts = try allocator.dupe(u64, &.{ 2, 1, 3 }),
                },
                .timestamps = .{ .time_ns = 100 },
            };
            defer first.deinit(allocator);

            var second = first;
            second.value = .{
                .count = 6,
                .sum = null,
                .scale = 0,
                .zero_count = 0,
                .positive_offset = -1,
                .positive_bucket_counts = try allocator.dupe(u64, &.{ 2, 1 }),
                .negative_offset = -1,
                .negative_bucket_counts = try allocator.dupe(u64, &.{ 1, 2 }),
            };
            second.timestamps = .{ .time_ns = 200 };
            defer second.deinit(allocator);

            if (scenario == .incoming_finer) {
                std.mem.swap(ExponentialHistogramDataPoint, &first.value, &second.value);
            }

            var measurements = Measurements{
                .scope = .{ .name = "test" },
                .instrumentKind = .Histogram,
                .instrumentOptions = .{ .name = "test-exponential-histogram" },
                .data = .{ .exponential_histogram = (&first)[0..1] },
            };

            if (scenario != .initial) {
                try ta.process(&measurements, view.TemporalityCumulative);
                measurements.data = .{ .exponential_histogram = (&second)[0..1] };
            }

            failing.fail_index = failing.alloc_index + failure_offset;
            failing.resize_fail_index = failing.resize_index;
            const result = ta.process(&measurements, view.TemporalityCumulative);
            if (failing.has_induced_failure) {
                try std.testing.expectError(error.OutOfMemory, result);
            } else {
                try result;
                const value = measurements.data.exponential_histogram[0].value;
                if (scenario == .initial) {
                    try std.testing.expectEqual(21, value.count);
                } else {
                    try std.testing.expectEqual(27, value.count);
                }
                break;
            }
        }
    }
}
