const std = @import("std");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pb_common = @import("../opentelemetry/proto/common/v1.pb.zig");
const pb_metrics = @import("../opentelemetry/proto/metrics/v1.pb.zig");
const pbutils = @import("../pbutils.zig");
const spec = @import("spec.zig");

// Supported instruments go here.
fn Instrument(comptime T: type) type {
    return struct {
        const Self = @This();

        inner: union {
            counter: Counter(T),
            histogram: Histogram(T),
        },
    };
}

pub const InstrumentOptions = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    /// ExplicitBuckets is used only in histograms to specify the bucket boundaries.
    /// Leave empty for default SDK buckets.
    explicitBuckets: ?[]const f64 = null,
    recordMinMax: bool = true,
    // Advisory parameters are in development, we don't support them here.
};

// A Counter is a monotonically increasing value used to record a sum of values.
// See https://opentelemetry.io/docs/specs/otel/metrics/api/#counter
pub fn Counter(comptime valueType: type) type {
    return struct {
        const Self = @This();

        options: InstrumentOptions,
        // We should keep track of the current value of the counter for each unique comibination of attribute.
        // At the same time, we don't want to allocate memory for each attribute set that comes in.
        // So we store all the counters in a single array and keep track of the state of each counter.
        cumulative: std.AutoHashMap(u64, valueType),

        pub fn init(options: InstrumentOptions, allocator: std.mem.Allocator) !Self {
            // Validate name, unit anddescription, optionally throw an error if non conformant.
            // See https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-name-syntax
            try spec.validateInstrumentOptions(options);
            return Self{
                .options = options,
                .cumulative = std.AutoHashMap(u64, valueType).init(allocator),
            };
        }

        /// Add the given delta to the counter, using the provided attributes.
        pub fn add(self: *Self, delta: valueType, attributes: ?pb_common.KeyValueList) !void {
            const key = pbutils.hashIdentifyAttributes(attributes);
            if (self.cumulative.getEntry(key)) |c| {
                c.value_ptr.* += delta;
            } else {
                try self.cumulative.put(key, delta);
            }
        }

        pub fn series(self: *Self) std.AutoHashMap(u64, valueType) {
            return self.cumulative;
        }
    };
}

pub fn Histogram(comptime valueType: type) type {
    return struct {
        const Self = @This();
        // Define a maximum number of buckets that can be used to record measurements.
        const maxBuckets = 1024;

        options: InstrumentOptions,
        // We should keep track of the current value of the counter for each unique comibination of attribute.
        // At the same time, we don't want to allocate memory for each attribute set that comes in.
        // So we store all the counters in a single array and keep track of the state of each counter.
        cumulative: std.AutoHashMap(u64, valueType),
        // Holds the counts of the values falling in each bucket for the histogram.
        // The buckets are defined by the user if explcitily provided, otherwise the default SDK specification
        // buckets are used.
        // Buckets are always defined as f64.
        buckets: []const f64,
        bucket_counts: std.AutoHashMap(u64, []usize),
        min: ?valueType = null,
        max: ?valueType = null,

        pub fn init(options: InstrumentOptions, allocator: std.mem.Allocator) !Self {
            // Validate name, unit anddescription, optionally throw an error if non conformant.
            // See https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-name-syntax
            try spec.validateInstrumentOptions(options);
            const buckets = options.explicitBuckets orelse spec.defaultHistogramBucketBoundaries;
            try spec.validateExplicitBuckets(buckets);

            return Self{
                .options = options,
                .cumulative = std.AutoHashMap(u64, valueType).init(allocator),
                .buckets = buckets,
                .bucket_counts = std.AutoHashMap(u64, []usize).init(allocator),
            };
        }

        /// Add the given value to the histogram, using the provided attributes.
        pub fn record(self: *Self, value: valueType, attributes: ?pb_common.KeyValueList) !void {
            const key = pbutils.hashIdentifyAttributes(attributes);
            if (self.cumulative.getEntry(key)) |c| {
                c.value_ptr.* += value;
            } else {
                try self.cumulative.put(key, value);
            }
            // Find the value for the bucket that the value falls in.
            // If the value is greater than the last bucket, it goes in the last bucket.
            // If the value is less than the first bucket, it goes in the first bucket.
            // Otherwise, it goes in the bucket for which the boundary is greater than or equal the value.
            const bucketIdx = self.findBucket(value);
            if (self.bucket_counts.getEntry(key)) |bc| {
                bc.value_ptr.*[bucketIdx] += 1;
            } else {
                var counts = [_]usize{0} ** maxBuckets;
                counts[bucketIdx] = 1;
                try self.bucket_counts.put(key, counts[0..self.buckets.len]);
            }

            // Update Min and Max values.
            if (self.options.recordMinMax) {
                if (self.max) |max| {
                    if (value > max) {
                        self.max = value;
                    }
                } else {
                    self.max = value;
                }
                if (self.min) |min| {
                    if (value < min) {
                        self.min = value;
                    }
                } else {
                    self.min = value;
                }
            }
        }

        fn findBucket(self: Self, value: valueType) usize {
            const vf64: f64 = @as(f64, @floatFromInt(value));
            for (self.buckets, 0..) |b, i| {
                if (b >= vf64) {
                    return i;
                }
            }
            // The last bucket is returned if the value is greater than it.
            return self.buckets.len - 1;
        }

        pub fn series(self: Self) std.AutoHashMap(u64, valueType) {
            return self.cumulative;
        }
        pub fn minAndMax(self: Self) std.meta.Tuple(&.{ valueType, valueType }) {
            return .{ self.min orelse 0, self.max orelse 0 };
        }
        pub fn bucketCounts(self: Self, attributes: ?pb_common.KeyValueList) ?[]usize {
            return self.bucket_counts.get(pbutils.hashIdentifyAttributes(attributes));
        }
    };
}

const MeterProvider = @import("meter.zig").MeterProvider;

test "meter can create counter instrument and record increase without attributes" {
    const mp = try MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(i32, .{ .name = "a-counter" });

    try counter.add(10, null);
    std.debug.assert(counter.series().count() == 1);
}

test "meter can create counter instrument and record increase with attributes" {
    const mp = try MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(i32, .{
        .name = "a-counter",
        .description = "a funny counter",
        .unit = "KiB",
    });

    try counter.add(1, null);
    std.debug.assert(counter.series().count() == 1);

    var attrs = std.ArrayList(pb_common.KeyValue).init(std.testing.allocator);
    defer attrs.deinit();
    try attrs.append(pb_common.KeyValue{ .key = .{ .Const = "some-key" }, .value = pb_common.AnyValue{ .value = .{ .string_value = .{ .Const = "42" } } } });
    try attrs.append(pb_common.KeyValue{ .key = .{ .Const = "another-key" }, .value = pb_common.AnyValue{ .value = .{ .int_value = 0x123456789 } } });

    try counter.add(2, pb_common.KeyValueList{ .values = attrs });
    std.debug.assert(counter.series().count() == 2);
}

test "meter can create histogram instrument and record value without explicit buckets" {
    const mp = try MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(i32, .{ .name = "anything" });

    try histogram.record(1, null);
    try histogram.record(5, null);
    try histogram.record(15, null);

    try std.testing.expectEqual(.{ 1, 15 }, histogram.minAndMax());
    std.debug.assert(histogram.series().count() == 1);
    const counts = histogram.bucketCounts(null).?;
    std.debug.assert(counts.len == spec.defaultHistogramBucketBoundaries.len);
    const expected_counts = &[_]usize{ 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(usize, expected_counts, counts);
}

test "meter can create histogram instrument and record value with explicit buckets" {
    const mp = try MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(i32, .{ .name = "a-histogram", .explicitBuckets = &.{ 1.0, 10.0, 100.0, 1000.0 } });

    try histogram.record(1, null);
    try histogram.record(5, null);
    try histogram.record(15, null);

    try std.testing.expectEqual(.{ 1, 15 }, histogram.minAndMax());
    std.debug.assert(histogram.series().count() == 1);
    const counts = histogram.bucketCounts(null).?;
    std.debug.assert(counts.len == 4);
    const expected_counts = &[_]usize{ 1, 1, 1, 0 };
    try std.testing.expectEqualSlices(usize, expected_counts, counts);
}
