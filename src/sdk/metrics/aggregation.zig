const std = @import("std");

const Attributes = @import("../../attributes.zig").Attributes;
const DataPoint = @import("../../api/metrics/measurement.zig").DataPoint;
const HistogramDataPoint = @import("../../api/metrics/measurement.zig").HistogramDataPoint;
const MeasurementsData = @import("../../api/metrics/measurement.zig").MeasurementsData;
const view = @import("view.zig");
const aggregation = @import("aggregation.zig");

/// Exponential histogram data point for Base2 exponential aggregation.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#base2-exponential-bucket-histogram-aggregation
pub const ExponentialHistogramDataPoint = struct {
    sum: ?f64, // Total sum of observations, might not exist when observations can be negative
    count: u64, // Total number of observations
    min: ?f64 = null, // Optional min value
    max: ?f64 = null, // Optional max value

    scale: i32, // Scale parameter (determines bucket resolution)
    zero_count: u64, // Count of zero values

    // Positive buckets
    positive_offset: i32, // Index offset for positive buckets
    positive_bucket_counts: []u64, // Counts for positive value buckets

    // Negative buckets
    negative_offset: i32, // Index offset for negative buckets
    negative_bucket_counts: []u64, // Counts for negative value buckets
};

/// Aggregates raw histogram data points using explicit bucket histogram aggregation.
/// This is the traditional histogram aggregation method with predefined bucket boundaries.
pub fn aggregateExplicitBucketHistogram(
    comptime T: type,
    allocator: std.mem.Allocator,
    data_points: []DataPoint(T),
    buckets: []const f64,
    record_min_max: bool,
) ![]DataPoint(HistogramDataPoint) {
    if (data_points.len == 0) return &[_]DataPoint(HistogramDataPoint){};

    // Group raw data points by attributes and compute histogram statistics
    var aggregated_state = std.HashMap(
        Attributes,
        HistogramDataPoint,
        Attributes.HashContext,
        std.hash_map.default_max_load_percentage,
    ).init(allocator);
    defer {
        var state_iter = aggregated_state.iterator();
        while (state_iter.next()) |v| {
            if (v.key_ptr.attributes) |attrs| allocator.free(attrs);
            allocator.free(v.value_ptr.bucket_counts);
        }
        aggregated_state.deinit();
    }

    // Aggregate raw measurements by attributes
    for (data_points) |dp| {
        const attributes = Attributes.with(dp.attributes);

        const result = try aggregated_state.getOrPut(attributes);
        if (!result.found_existing) {
            // Create a new entry in the state for these attributes:
            // - bucket counts are allocated and initialized to 0.
            // - all other fields are set to null or empty.
            // Note: we need n+1 buckets for n boundaries (the last bucket is for values >= last boundary)
            var bucket_counts = try allocator.alloc(u64, buckets.len + 1);
            for (0..buckets.len + 1) |i| {
                bucket_counts[i] = 0;
            }
            result.value_ptr.* = HistogramDataPoint{
                .explicit_bounds = buckets,
                .bucket_counts = bucket_counts,
                .sum = null,
                .count = 0,
                .min = null,
                .max = null,
            };
            // Duplicate the attributes for the new entry
            result.key_ptr.* = Attributes.with(try attributes.dupe(allocator));
        }

        // Now update the aggregated value with the current data point.
        var state_entry = result.value_ptr;

        const f64_val: f64 = switch (T) {
            u16, u32, u64, i16, i32, i64 => @as(f64, @floatFromInt(dp.value)),
            f32, f64 => @as(f64, dp.value),
            // Other compile-time checks ensure we don't get here.
            else => unreachable,
        };

        // addition will fail in (the unlikely) case of overflow
        // sum
        state_entry.sum = switch (T) {
            // we don't set sum when the value can be negative
            i16, i32, i64 => null,
            u16, u32, u64, f32, f64 => if (state_entry.sum) |curr| curr + f64_val else f64_val,
            else => unreachable,
        };
        // total count of observations
        state_entry.count = try std.math.add(u64, state_entry.count, 1);
        // min and max
        if (record_min_max) {
            state_entry.min = if (state_entry.min) |curr| @min(curr, f64_val) else f64_val;
            state_entry.max = if (state_entry.max) |curr| @max(curr, f64_val) else f64_val;
        }
        // Find the bucket that the value falls in.
        // Values are placed in the first bucket where value <= boundary.
        // If value is greater than all boundaries, it goes in the overflow bucket (last bucket).
        var bucket_index = buckets.len; // Default to overflow bucket
        for (buckets, 0..) |boundary, i| {
            if (f64_val <= boundary) {
                bucket_index = i;
                break;
            }
        }
        state_entry.bucket_counts[bucket_index] += 1;
    }

    // Convert aggregated state to final data points
    var result_data_points = try allocator.alloc(DataPoint(HistogramDataPoint), aggregated_state.count());
    var iter = aggregated_state.iterator();
    var idx: usize = 0;
    while (iter.next()) |entry| {
        var bcounts = try allocator.alloc(u64, buckets.len + 1);
        for (entry.value_ptr.bucket_counts, 0..) |b, i| {
            bcounts[i] = b;
        }
        const val = HistogramDataPoint{
            .bucket_counts = bcounts[0..],
            .explicit_bounds = entry.value_ptr.explicit_bounds,
            .sum = entry.value_ptr.sum,
            .count = entry.value_ptr.count,
            .min = entry.value_ptr.min,
            .max = entry.value_ptr.max,
        };
        result_data_points[idx] = DataPoint(HistogramDataPoint){
            .value = val,
            .attributes = try entry.key_ptr.dupe(allocator),
        };
        idx += 1;
    }

    return result_data_points;
}

/// Aggregates raw histogram data points using Base2 exponential bucket histogram aggregation.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#base2-exponential-bucket-histogram-aggregation
pub fn aggregateExponentialBucketHistogram(
    comptime T: type,
    allocator: std.mem.Allocator,
    data_points: []DataPoint(T),
    max_scale: i32,
    max_size: u32,
    record_min_max: bool,
) ![]DataPoint(ExponentialHistogramDataPoint) {
    if (data_points.len == 0) return &[_]DataPoint(ExponentialHistogramDataPoint){};

    // Group raw data points by attributes and compute exponential histogram statistics
    var aggregated_state = std.HashMap(
        Attributes,
        ExponentialHistogramState,
        Attributes.HashContext,
        std.hash_map.default_max_load_percentage,
    ).init(allocator);
    defer {
        var state_iter = aggregated_state.iterator();
        while (state_iter.next()) |v| {
            if (v.key_ptr.attributes) |attrs| allocator.free(attrs);
            v.value_ptr.deinit(allocator);
        }
        aggregated_state.deinit();
    }

    // Aggregate raw measurements by attributes
    for (data_points) |dp| {
        const attributes = Attributes.with(dp.attributes);

        const result = try aggregated_state.getOrPut(attributes);
        if (!result.found_existing) {
            result.value_ptr.* = ExponentialHistogramState.init(max_scale);
            // Duplicate the attributes for the new entry
            result.key_ptr.* = Attributes.with(try attributes.dupe(allocator));
        }

        // Add the value to the exponential histogram state
        const f64_val: f64 = switch (T) {
            u16, u32, u64, i16, i32, i64 => @as(f64, @floatFromInt(dp.value)),
            f32, f64 => @as(f64, dp.value),
            else => unreachable,
        };

        try result.value_ptr.addValue(allocator, f64_val, max_size, record_min_max, T);
    }

    // Convert aggregated state to final data points
    var result_data_points = try allocator.alloc(DataPoint(ExponentialHistogramDataPoint), aggregated_state.count());
    var iter = aggregated_state.iterator();
    var idx: usize = 0;
    while (iter.next()) |entry| {
        const exp_hist = try entry.value_ptr.toDataPoint(allocator);
        result_data_points[idx] = DataPoint(ExponentialHistogramDataPoint){
            .value = exp_hist,
            .attributes = try entry.key_ptr.dupe(allocator),
        };
        idx += 1;
    }

    return result_data_points;
}

// Internal state for building exponential histograms
const ExponentialHistogramState = struct {
    scale: i32,
    sum: ?f64,
    count: u64,
    min: ?f64,
    max: ?f64,
    zero_count: u64,

    positive_buckets: std.AutoArrayHashMap(i32, u64),
    negative_buckets: std.AutoArrayHashMap(i32, u64),

    fn init(scale: i32) ExponentialHistogramState {
        return ExponentialHistogramState{
            .scale = scale,
            .sum = null,
            .count = 0,
            .min = null,
            .max = null,
            .zero_count = 0,
            .positive_buckets = std.AutoArrayHashMap(i32, u64).init(std.heap.page_allocator),
            .negative_buckets = std.AutoArrayHashMap(i32, u64).init(std.heap.page_allocator),
        };
    }

    fn deinit(self: *ExponentialHistogramState, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.positive_buckets.deinit();
        self.negative_buckets.deinit();
    }

    fn addValue(
        self: *ExponentialHistogramState,
        allocator: std.mem.Allocator,
        value: f64,
        max_size: u32,
        record_min_max: bool,
        comptime T: type,
    ) !void {
        _ = allocator;
        _ = max_size; // TODO: implement scale reduction when bucket count exceeds max_size

        // Update basic statistics
        self.sum = switch (T) {
            i16, i32, i64 => null, // don't set sum when value can be negative
            u16, u32, u64, f32, f64 => if (self.sum) |curr| curr + value else value,
            else => unreachable,
        };
        self.count += 1;

        if (record_min_max) {
            self.min = if (self.min) |curr| @min(curr, value) else value;
            self.max = if (self.max) |curr| @max(curr, value) else value;
        }

        // Handle zero values
        if (value == 0.0) {
            self.zero_count += 1;
            return;
        }

        // Calculate bucket index using Base2 exponential mapping
        const bucket_index = getBucketIndex(value, self.scale);

        if (value > 0) {
            const result = try self.positive_buckets.getOrPut(bucket_index);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
        } else {
            const result = try self.negative_buckets.getOrPut(bucket_index);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
        }
    }

    fn toDataPoint(self: *ExponentialHistogramState, allocator: std.mem.Allocator) !ExponentialHistogramDataPoint {
        // Convert sparse bucket maps to dense arrays with offsets
        const positive_result = try bucketsToArrays(allocator, &self.positive_buckets);
        const negative_result = try bucketsToArrays(allocator, &self.negative_buckets);

        return ExponentialHistogramDataPoint{
            .sum = self.sum,
            .count = self.count,
            .min = self.min,
            .max = self.max,
            .scale = self.scale,
            .zero_count = self.zero_count,
            .positive_offset = positive_result.offset,
            .positive_bucket_counts = positive_result.counts,
            .negative_offset = negative_result.offset,
            .negative_bucket_counts = negative_result.counts,
        };
    }
};

// Convert sparse bucket map to dense array with offset
const BucketArrayResult = struct {
    offset: i32,
    counts: []u64,
};

fn bucketsToArrays(allocator: std.mem.Allocator, buckets: *std.AutoArrayHashMap(i32, u64)) !BucketArrayResult {
    if (buckets.count() == 0) {
        return BucketArrayResult{
            .offset = 0,
            .counts = &[_]u64{},
        };
    }

    // Find min and max bucket indices
    var min_index: i32 = std.math.maxInt(i32);
    var max_index: i32 = std.math.minInt(i32);

    var iter = buckets.iterator();
    while (iter.next()) |entry| {
        min_index = @min(min_index, entry.key_ptr.*);
        max_index = @max(max_index, entry.key_ptr.*);
    }

    // Create dense array
    const array_size = @as(usize, @intCast(max_index - min_index + 1));
    const counts = try allocator.alloc(u64, array_size);
    @memset(counts, 0);

    // Fill the array
    iter = buckets.iterator();
    while (iter.next()) |entry| {
        const array_index = @as(usize, @intCast(entry.key_ptr.* - min_index));
        counts[array_index] = entry.value_ptr.*;
    }

    return BucketArrayResult{
        .offset = min_index,
        .counts = counts,
    };
}

/// Calculate bucket index for Base2 exponential histogram
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#exponential-bucket-histogram-aggregation
fn getBucketIndex(value: f64, scale: i32) i32 {
    if (value == 0.0) return 0;

    const abs_value = @abs(value);
    const log_value = std.math.log2(abs_value);
    const scaled_log = log_value * std.math.pow(f64, 2.0, @as(f64, @floatFromInt(scale)));

    return @as(i32, @intFromFloat(@floor(scaled_log)));
}

test "explicit bucket histogram aggregation" {
    const allocator = std.testing.allocator;

    // Create test data points
    var data_points = [_]DataPoint(u32){
        .{ .value = 1, .attributes = null },
        .{ .value = 5, .attributes = null },
        .{ .value = 15, .attributes = null },
    };

    const buckets = &[_]f64{ 1.0, 10.0, 100.0, 1000.0, std.math.inf(f64) };

    const result = try aggregateExplicitBucketHistogram(u32, allocator, &data_points, buckets, true);
    defer {
        for (result) |*dp| {
            dp.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const hist = result[0].value;
    try std.testing.expectEqual(@as(u64, 3), hist.count);
    try std.testing.expectEqual(@as(f64, 21.0), hist.sum.?);
    try std.testing.expectEqual(@as(f64, 1.0), hist.min.?);
    try std.testing.expectEqual(@as(f64, 15.0), hist.max.?);

    // Values: 1 goes in bucket 0 (≤1.0), 5 goes in bucket 1 (≤10.0), 15 goes in bucket 2 (≤100.0)
    // Expected individual bucket counts: [1, 1, 1, 0, 0, 0]
    const expected_counts = &[_]u64{ 1, 1, 1, 0, 0, 0 };
    try std.testing.expectEqualSlices(u64, expected_counts, hist.bucket_counts);
}

test "exponential bucket histogram aggregation" {
    const allocator = std.testing.allocator;

    // Create test data points
    var data_points = [_]DataPoint(u32){
        .{ .value = 1, .attributes = null },
        .{ .value = 2, .attributes = null },
        .{ .value = 4, .attributes = null },
    };

    const result = try aggregateExponentialBucketHistogram(u32, allocator, &data_points, 4, 160, true);
    defer {
        for (result) |*dp| {
            dp.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const exp_hist = result[0].value;
    try std.testing.expectEqual(@as(u64, 3), exp_hist.count);
    try std.testing.expectEqual(@as(f64, 7.0), exp_hist.sum.?);
    try std.testing.expectEqual(@as(f64, 1.0), exp_hist.min.?);
    try std.testing.expectEqual(@as(f64, 4.0), exp_hist.max.?);
    try std.testing.expectEqual(@as(u64, 0), exp_hist.zero_count);
}

test "exponential bucket histogram aggregation e2e" {
    const allocator = std.testing.allocator;

    // Create some test data points
    var data_points = try allocator.alloc(DataPoint(f64), 3);
    defer allocator.free(data_points);

    data_points[0] = try DataPoint(f64).new(allocator, 1.5, .{});
    defer data_points[0].deinit(allocator);

    data_points[1] = try DataPoint(f64).new(allocator, 2.3, .{});
    defer data_points[1].deinit(allocator);

    data_points[2] = try DataPoint(f64).new(allocator, 4.7, .{});
    defer data_points[2].deinit(allocator);

    // Test exponential bucket histogram aggregation
    const exponential_result = try aggregation.aggregateExponentialBucketHistogram(f64, allocator, data_points, 20, // scale
        1024, // max size
        true // record min/max
    );
    defer {
        for (exponential_result) |*dp| {
            dp.deinit(allocator);
        }
        allocator.free(exponential_result);
    }

    try std.testing.expectEqual(@as(usize, 1), exponential_result.len);

    const exp_dp = exponential_result[0];
    try std.testing.expectEqual(@as(u64, 3), exp_dp.value.count);
    try std.testing.expectEqual(@as(f64, 8.5), exp_dp.value.sum.?);
    try std.testing.expectEqual(@as(f64, 1.5), exp_dp.value.min.?);
    try std.testing.expectEqual(@as(f64, 4.7), exp_dp.value.max.?);

    // Test explicit bucket histogram aggregation
    const buckets = [_]f64{ 1.0, 2.0, 3.0, 5.0 };
    const explicit_result = try aggregation.aggregateExplicitBucketHistogram(f64, allocator, data_points, &buckets, true // record min/max
    );
    defer {
        for (explicit_result) |*dp| {
            dp.deinit(allocator);
        }
        allocator.free(explicit_result);
    }

    try std.testing.expectEqual(@as(usize, 1), explicit_result.len);

    const exp_bucket_dp = explicit_result[0];
    try std.testing.expectEqual(@as(u64, 3), exp_bucket_dp.value.count);
    try std.testing.expectEqual(@as(f64, 8.5), exp_bucket_dp.value.sum.?);
    try std.testing.expectEqual(@as(f64, 1.5), exp_bucket_dp.value.min.?);
    try std.testing.expectEqual(@as(f64, 4.7), exp_bucket_dp.value.max.?);

    // Check bucket counts: 1.5 goes in bucket [1.0, 2.0), 2.3 goes in [2.0, 3.0), 4.7 goes in [3.0, 5.0)
    const expected_counts = [_]u64{ 0, 1, 1, 1, 0 }; // buckets: <1.0, [1.0,2.0), [2.0,3.0), [3.0,5.0), >=5.0
    try std.testing.expectEqualSlices(u64, &expected_counts, exp_bucket_dp.value.bucket_counts);
}

test "aggregation enum has exponential bucket histogram option" {
    const exp_agg = view.Aggregation.ExponentialBucketHistogram;
    try std.testing.expectEqual(view.Aggregation.ExponentialBucketHistogram, exp_agg);
}
