const std = @import("std");

const Attribute = @import("../../attributes.zig").Attribute;
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
    record_sum: bool,
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

        if (record_sum) state_entry.sum = (state_entry.sum orelse 0) + f64_val;
        // total count of observations, addition will fail in (the unlikely) case of overflow
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
    record_sum: bool,
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
            result.value_ptr.* = ExponentialHistogramState.init(allocator, max_scale);
            // Duplicate the attributes for the new entry
            result.key_ptr.* = Attributes.with(try attributes.dupe(allocator));
        }

        // Add the value to the exponential histogram state
        const f64_val: f64 = switch (T) {
            u16, u32, u64, i16, i32, i64 => @as(f64, @floatFromInt(dp.value)),
            f32, f64 => @as(f64, dp.value),
            else => unreachable,
        };

        try result.value_ptr.addValue(allocator, f64_val, max_size, record_min_max, record_sum);
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

    positive_buckets: std.AutoArrayHashMapUnmanaged(i32, u64),
    negative_buckets: std.AutoArrayHashMapUnmanaged(i32, u64),
    const min_scale: i32 = -10;

    fn init(allocator: std.mem.Allocator, scale: i32) ExponentialHistogramState {
        _ = allocator;
        return ExponentialHistogramState{
            .scale = scale,
            .sum = null,
            .count = 0,
            .min = null,
            .max = null,
            .zero_count = 0,
            .positive_buckets = .empty,
            .negative_buckets = .empty,
        };
    }

    fn deinit(self: *ExponentialHistogramState, allocator: std.mem.Allocator) void {
        self.positive_buckets.deinit(allocator);
        self.negative_buckets.deinit(allocator);
    }

    fn addValue(
        self: *ExponentialHistogramState,
        allocator: std.mem.Allocator,
        value: f64,
        max_size: u32,
        record_min_max: bool,
        record_sum: bool,
    ) !void {
        // Handle zero values
        if (value == 0.0) {
            self.zero_count += 1;
        } else {
            // Calculate bucket index using Base2 exponential mapping
            var bucket_index = getBucketIndex(value, self.scale);
            const buckets: *std.AutoArrayHashMapUnmanaged(i32, u64) = if (value > 0)
                &self.positive_buckets
            else
                &self.negative_buckets;

            var range = bucketIndexRangeWithNewIndex(buckets, bucket_index);
            var downscale_steps: i32 = 0;

            while (range.width() > max_size) {
                if (self.scale - downscale_steps <= min_scale) return;
                range.min = @divFloor(range.min, 2);
                range.max = @divFloor(range.max, 2);
                bucket_index = @divFloor(bucket_index, 2);
                downscale_steps += 1;
            }

            if (downscale_steps != 0) {
                const index_divisor = std.math.pow(i64, 2, downscale_steps);
                // Scale down both bucket maps, because they share the same scale
                var temp_positive_buckets = try downscaleBuckets(allocator, self.positive_buckets, index_divisor);
                defer temp_positive_buckets.deinit(allocator);

                var temp_negative_buckets = try downscaleBuckets(allocator, self.negative_buckets, index_divisor);
                defer temp_negative_buckets.deinit(allocator);

                const BucketMap = std.AutoArrayHashMapUnmanaged(i32, u64);
                // Swap only after both shrink operations succeed
                // Move the old maps to temporary variables and release them using defer
                std.mem.swap(BucketMap, &self.positive_buckets, &temp_positive_buckets);
                std.mem.swap(BucketMap, &self.negative_buckets, &temp_negative_buckets);
                self.scale -= downscale_steps;
            }

            const result = try buckets.getOrPutValue(allocator, bucket_index, 0);
            result.value_ptr.* += 1;
        }
        // Update basic statistics
        if (record_sum) self.sum = (self.sum orelse 0) + value;
        self.count += 1;

        if (record_min_max) {
            self.min = if (self.min) |curr| @min(curr, value) else value;
            self.max = if (self.max) |curr| @max(curr, value) else value;
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

const BucketIndexRange = struct {
    min: i32,
    max: i32,

    fn width(self: @This()) i64 {
        return @as(i64, self.max) - @as(i64, self.min) + 1;
    }
};

fn bucketIndexRangeWithNewIndex(
    buckets: *const std.AutoArrayHashMapUnmanaged(i32, u64),
    new_index: i32,
) BucketIndexRange {
    const keys = buckets.keys();
    if (keys.len == 0) return .{ .min = new_index, .max = new_index };

    var min_idx, var max_idx = std.mem.minMax(i32, keys);
    min_idx = @min(new_index, min_idx);
    max_idx = @max(new_index, max_idx);
    return .{ .min = min_idx, .max = max_idx };
}

fn downscaleBuckets(
    allocator: std.mem.Allocator,
    buckets: std.AutoArrayHashMapUnmanaged(i32, u64),
    index_divisor: i64,
) !std.AutoArrayHashMapUnmanaged(i32, u64) {
    var temp_buckets: std.AutoArrayHashMapUnmanaged(i32, u64) = .empty;
    errdefer temp_buckets.deinit(allocator);

    for (
        buckets.keys(),
        buckets.values(),
    ) |idx, count| {
        const new_idx: i32 = @intCast(@divFloor(idx, index_divisor));
        const result = try temp_buckets.getOrPutValue(allocator, new_idx, 0);
        result.value_ptr.* += count;
    }

    return temp_buckets;
}

// Convert sparse bucket map to dense array with offset
const BucketArrayResult = struct {
    offset: i32,
    counts: []u64,
};

fn bucketsToArrays(allocator: std.mem.Allocator, buckets: *std.AutoArrayHashMapUnmanaged(i32, u64)) !BucketArrayResult {
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

    const result = try aggregateExplicitBucketHistogram(u32, allocator, &data_points, buckets, true, true);
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

    const result = try aggregateExponentialBucketHistogram(u32, allocator, &data_points, 4, 160, true, true);
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
        true, // record min/max
        true // record sum
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
    const explicit_result = try aggregation.aggregateExplicitBucketHistogram(f64, allocator, data_points, &buckets, true, // record min/max
        true // record sum
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

test "exponential bucket histogram respects max size" {
    const allocator = std.testing.allocator;

    var data_points = [_]DataPoint(f64){
        .{ .value = 1.5, .attributes = null },
        .{ .value = 6, .attributes = null },
    };

    const result = try aggregateExponentialBucketHistogram(f64, allocator, &data_points, 0, 2, true, true);
    defer {
        for (result) |*dp| {
            dp.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const exp_hist = result[0].value;
    try std.testing.expect(exp_hist.scale == -1);
    try std.testing.expect(exp_hist.positive_offset == 0);
    try std.testing.expectEqualSlices(
        u64,
        &[_]u64{ 1, 1 },
        exp_hist.positive_bucket_counts,
    );
    try std.testing.expect(exp_hist.count == 2);
    try std.testing.expect(exp_hist.negative_bucket_counts.len == 0);
}

test "exponential bucket histogram downscale multiple times to respects max size" {
    const allocator = std.testing.allocator;

    var data_points = [_]DataPoint(f64){
        .{ .value = 1.5, .attributes = null },
        .{ .value = 24, .attributes = null },
    };

    const result = try aggregateExponentialBucketHistogram(f64, allocator, &data_points, 0, 2, true, true);
    defer {
        for (result) |*dp| {
            dp.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const exp_hist = result[0].value;
    try std.testing.expect(exp_hist.scale == -2);
    try std.testing.expect(exp_hist.positive_offset == 0);
    try std.testing.expectEqualSlices(
        u64,
        &[_]u64{ 1, 1 },
        exp_hist.positive_bucket_counts,
    );
    try std.testing.expect(exp_hist.count == 2);
    try std.testing.expect(exp_hist.negative_bucket_counts.len == 0);
}

test "exponential bucket histogram downscale with mixed positive and negative values to respect max size" {
    const allocator = std.testing.allocator;

    var data_points = [_]DataPoint(f64){
        .{ .value = -0.375, .attributes = null },
        .{ .value = -0.75, .attributes = null },
        .{ .value = 1.5, .attributes = null },
        .{ .value = 6, .attributes = null },
    };

    const result = try aggregateExponentialBucketHistogram(f64, allocator, &data_points, 0, 2, true, true);
    defer {
        for (result) |*dp| {
            dp.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const exp_hist = result[0].value;
    try std.testing.expect(exp_hist.scale == -1);
    try std.testing.expect(exp_hist.positive_offset == 0);
    try std.testing.expectEqualSlices(
        u64,
        &[_]u64{ 1, 1 },
        exp_hist.positive_bucket_counts,
    );
    try std.testing.expect(exp_hist.negative_offset == -1);
    try std.testing.expectEqualSlices(
        u64,
        &[_]u64{2},
        exp_hist.negative_bucket_counts,
    );
    try std.testing.expect(exp_hist.count == 4);
}

test "exponential histograms scale down independently per attribute" {
    const allocator = std.testing.allocator;
    var attrs_a = [_]Attribute{.{ .key = "a", .value = .{ .int = 0 } }};
    var attrs_b = [_]Attribute{.{ .key = "b", .value = .{ .int = 0 } }};

    var data_points = [_]DataPoint(f64){
        .{ .value = 1.5, .attributes = &attrs_a },
        .{ .value = 3, .attributes = &attrs_a },
        .{ .value = 1.5, .attributes = &attrs_b },
        .{ .value = 6, .attributes = &attrs_b },
    };

    const result = try aggregateExponentialBucketHistogram(f64, allocator, &data_points, 0, 2, true, true);
    defer {
        for (result) |*dp| {
            dp.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    for (result) |r| {
        const attrs = r.attributes.?;
        if (std.mem.eql(u8, attrs[0].key, "a")) {
            try std.testing.expect(r.value.scale == 0);
        } else if (std.mem.eql(u8, attrs[0].key, "b")) {
            try std.testing.expect(r.value.scale == -1);
        } else {
            return error.UnexpectedAttribute;
        }

        try std.testing.expect(r.value.positive_offset == 0);
        try std.testing.expectEqualSlices(
            u64,
            &[_]u64{ 1, 1 },
            r.value.positive_bucket_counts,
        );
        try std.testing.expect(r.value.count == 2);
    }
}

test "clean up after a memory allocation failure while shrinking the exponential histogram" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();

    var state = ExponentialHistogramState.init(allocator, 0);
    defer state.deinit(allocator);

    for ([_]f64{ -0.375, -0.75, 1.5 }) |v| {
        try state.addValue(allocator, v, 2, true, true);
    }
    // Allow allocation of the positive temporary map, then fail the negative one
    failing.fail_index = failing.alloc_index + 1;

    try std.testing.expectError(
        error.OutOfMemory,
        state.addValue(allocator, 6, 2, true, true),
    );

    try std.testing.expect(state.scale == 0);
    try std.testing.expect(state.positive_buckets.count() == 1);
    try std.testing.expect(state.positive_buckets.get(0) == 1);
    try std.testing.expect(state.negative_buckets.count() == 2);
    try std.testing.expect(state.negative_buckets.get(-2) == 1);
    try std.testing.expect(state.negative_buckets.get(-1) == 1);
}

test "exponential histogram scale does not fall below lower limit" {
    const allocator = std.testing.allocator;

    var data_points = [_]DataPoint(f64){
        .{ .value = 0.5, .attributes = null },
        .{ .value = 0x1p600, .attributes = null },
        // Create a condition requiring reduction to -11 to fit in max_size = 2 using denormalized numbers.
        // Stop reduction at the lower limit (-10) and ensure this value is excluded from aggregation.
        .{ .value = 0x1p-1074, .attributes = null },
    };

    const result = try aggregateExponentialBucketHistogram(f64, allocator, &data_points, -9, 2, true, true);
    defer {
        for (result) |*dp| {
            dp.deinit(allocator);
        }
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 1), result.len);
    const exp_hist = result[0].value;
    try std.testing.expect(exp_hist.scale == -10);
    try std.testing.expect(exp_hist.positive_offset == -1);
    try std.testing.expectEqualSlices(
        u64,
        &[_]u64{ 1, 1 },
        exp_hist.positive_bucket_counts,
    );
    try std.testing.expect(exp_hist.count == 2);
    try std.testing.expect(exp_hist.min == 0.5);
}
