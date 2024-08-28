const std = @import("std");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("../opentelemetry/proto/common/v1.pb.zig");
const pbutils = @import("../pbutils.zig");
const spec = @import("spec.zig");

pub const Kind = enum {
    Counter,
    Histogram,
    Gauge,

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            .Counter => "Counter",
            .Histogram => "Histogram",
            .Gauge => "Gauge",
        };
    }
};

// TODO this should be the abstraction containing all instruments.
// We should have a single struct that contains all the instruments.
// The current Counter(T), Histogra(T) and Gauge(T) should be part of the instrument and
// when the Meter wants to create a new instrument, it should call the appropriate method.
//In this way, storing the instruments in a single hashmap also contains the concrete type of the instrument.
pub const Instrument = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    kind: Kind,
    opts: InstrumentOptions,
    data: union(enum) {
        Counter_u16: Counter(u16),
        Counter_u32: Counter(u32),
        Counter_u64: Counter(u64),
        Histogram_u16: Histogram(u16),
        Histogram_u32: Histogram(u32),
        Histogram_u64: Histogram(u64),
        Histogram_f32: Histogram(f32),
        Histogram_f64: Histogram(f64),
        Gauge_i16: Gauge(i16),
        Gauge_i32: Gauge(i32),
        Gauge_i64: Gauge(i64),
        Gauge_f32: Gauge(f32),
        Gauge_f64: Gauge(f64),
    },

    pub fn Get(kind: Kind, opts: InstrumentOptions, allocator: std.mem.Allocator) !Self {
        // Validate name, unit anddescription, optionally throw an error if non conformant.
        // See https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-name-syntax
        try spec.validateInstrumentOptions(opts);
        return Self{
            .allocator = allocator,
            .kind = kind,
            .opts = opts,
            .data = undefined,
        };
    }

    pub fn counter(self: *Self, comptime T: type) !Counter(T) {
        const c = Counter(T).init(self.opts, self.allocator);
        self.data = switch (T) {
            u16 => .{ .Counter_u16 = c },
            u32 => .{ .Counter_u32 = c },
            u64 => .{ .Counter_u64 = c },
            else => {
                std.debug.print("Unsupported monotonic counter value type: {s}\n", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return c;
    }

    pub fn histogram(self: *Self, comptime T: type) !Histogram(T) {
        const h = try Histogram(T).init(self.opts, self.allocator);
        self.data = switch (T) {
            u16 => .{ .Histogram_u16 = h },
            u32 => .{ .Histogram_u32 = h },
            u64 => .{ .Histogram_u64 = h },
            f32 => .{ .Histogram_f32 = h },
            f64 => .{ .Histogram_f64 = h },
            else => {
                std.debug.print("Unsupported histogram value type: {s}\n", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return h;
    }

    pub fn gauge(self: *Self, comptime T: type) !Gauge(T) {
        const g = Gauge(T).init(self.opts, self.allocator);
        self.data = switch (T) {
            i16 => .{ .Gauge_i16 = g },
            i32 => .{ .Gauge_i32 = g },
            i64 => .{ .Gauge_i64 = g },
            f32 => .{ .Gauge_f32 = g },
            f64 => .{ .Gauge_f64 = g },
            else => {
                std.debug.print("Unsupported gauge value type: {s}\n", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return g;
    }
};

/// InstrumentOptions is used to configure the instrument.
/// Base instrument options are name, description and unit.
/// Kind is inferred from the concrete type of the instrument.
pub const InstrumentOptions = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    /// ExplicitBuckets is used only in histograms to specify the bucket boundaries.
    /// Leave empty for default SDK buckets.
    explicitBuckets: ?[]const f64 = null,
    recordMinMax: bool = true,
    // Advisory parameters are in development, we don't support them yet, so we set to null.
    advisory: ?pbcommon.KeyValueList = null,
};

// A Counter is a monotonically increasing value used to record cumulative events.
// See https://opentelemetry.io/docs/specs/otel/metrics/api/#counter
pub fn Counter(comptime T: type) type {
    return struct {
        const Self = @This();

        options: InstrumentOptions,
        // We should keep track of the current value of the counter for each unique comibination of attribute.
        // At the same time, we don't want to allocate memory for each attribute set that comes in.
        // So we store all the counters in a single array and keep track of the state of each counter.
        cumulative: std.AutoHashMap(u64, T),

        pub fn init(options: InstrumentOptions, allocator: std.mem.Allocator) Self {
            return Self{
                .options = options,
                .cumulative = std.AutoHashMap(u64, T).init(allocator),
            };
        }

        /// Add the given delta to the counter, using the provided attributes.
        pub fn add(self: *Self, delta: T, attributes: ?pbcommon.KeyValueList) !void {
            const key = pbutils.hashIdentifyAttributes(attributes);
            if (self.cumulative.getEntry(key)) |c| {
                c.value_ptr.* += delta;
            } else {
                try self.cumulative.put(key, delta);
            }
        }
    };
}

pub fn Histogram(comptime T: type) type {
    return struct {
        const Self = @This();
        // Define a maximum number of buckets that can be used to record measurements.
        const maxBuckets = 1024;

        options: InstrumentOptions,
        // We should keep track of the current value of the counter for each unique comibination of attribute.
        // At the same time, we don't want to allocate memory for each attribute set that comes in.
        // So we store all the counters in a single array and keep track of the state of each counter.
        cumulative: std.AutoHashMap(u64, T),
        // Holds the counts of the values falling in each bucket for the histogram.
        // The buckets are defined by the user if explcitily provided, otherwise the default SDK specification
        // buckets are used.
        // Buckets are always defined as f64.
        buckets: []const f64,
        bucket_counts: std.AutoHashMap(u64, []usize),
        min: ?T = null,
        max: ?T = null,

        pub fn init(options: InstrumentOptions, allocator: std.mem.Allocator) !Self {
            // buckets are part of the options, so we validate them from there.
            const buckets = options.explicitBuckets orelse spec.defaultHistogramBucketBoundaries;
            try spec.validateExplicitBuckets(buckets);

            return Self{
                .options = options,
                .cumulative = std.AutoHashMap(u64, T).init(allocator),
                .buckets = buckets,
                .bucket_counts = std.AutoHashMap(u64, []usize).init(allocator),
            };
        }

        /// Add the given value to the histogram, using the provided attributes.
        pub fn record(self: *Self, value: T, attributes: ?pbcommon.KeyValueList) !void {
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

        fn findBucket(self: Self, value: T) usize {
            const vf64: f64 = @as(f64, @floatFromInt(value));
            for (self.buckets, 0..) |b, i| {
                if (b >= vf64) {
                    return i;
                }
            }
            // The last bucket is returned if the value is greater than it.
            return self.buckets.len - 1;
        }
    };
}

pub fn Gauge(comptime T: type) type {
    return struct {
        const Self = @This();

        options: InstrumentOptions,
        values: std.AutoHashMap(u64, T),

        pub fn init(options: InstrumentOptions, allocator: std.mem.Allocator) Self {
            return Self{
                .options = options,
                .values = std.AutoHashMap(u64, T).init(allocator),
            };
        }

        /// Record the given value to the gauge, using the provided attributes.
        pub fn record(self: *Self, value: T, attributes: ?pbcommon.KeyValueList) !void {
            const key = pbutils.hashIdentifyAttributes(attributes);
            try self.values.put(key, value);
        }
    };
}

const MeterProvider = @import("meter.zig").MeterProvider;

test "meter can create counter instrument and record increase without attributes" {
    const mp = try MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(u32, .{ .name = "a-counter" });

    try counter.add(10, null);
    std.debug.assert(counter.cumulative.count() == 1);
}

test "meter can create counter instrument and record increase with attributes" {
    const mp = try MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(u32, .{
        .name = "a-counter",
        .description = "a funny counter",
        .unit = "KiB",
    });

    try counter.add(1, null);
    std.debug.assert(counter.cumulative.count() == 1);

    var attrs = std.ArrayList(pbcommon.KeyValue).init(std.testing.allocator);
    defer attrs.deinit();
    try attrs.append(pbcommon.KeyValue{ .key = .{ .Const = "some-key" }, .value = pbcommon.AnyValue{ .value = .{ .string_value = .{ .Const = "42" } } } });
    try attrs.append(pbcommon.KeyValue{ .key = .{ .Const = "another-key" }, .value = pbcommon.AnyValue{ .value = .{ .int_value = 0x123456789 } } });

    try counter.add(2, pbcommon.KeyValueList{ .values = attrs });
    std.debug.assert(counter.cumulative.count() == 2);
}

test "meter can create histogram instrument and record value without explicit buckets" {
    const mp = try MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "anything" });

    try histogram.record(1, null);
    try histogram.record(5, null);
    try histogram.record(15, null);

    try std.testing.expectEqual(.{ 1, 15 }, .{ histogram.min.?, histogram.max.? });
    std.debug.assert(histogram.cumulative.count() == 1);
    const counts = histogram.bucket_counts.get(pbutils.hashIdentifyAttributes(null)).?;
    std.debug.assert(counts.len == spec.defaultHistogramBucketBoundaries.len);
    const expected_counts = &[_]usize{ 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(usize, expected_counts, counts);
}

test "meter can create histogram instrument and record value with explicit buckets" {
    const mp = try MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "a-histogram", .explicitBuckets = &.{ 1.0, 10.0, 100.0, 1000.0 } });

    try histogram.record(1, null);
    try histogram.record(5, null);
    try histogram.record(15, null);

    try std.testing.expectEqual(.{ 1, 15 }, .{ histogram.min.?, histogram.max.? });
    std.debug.assert(histogram.cumulative.count() == 1);
    const counts = histogram.bucket_counts.get(pbutils.hashIdentifyAttributes(null)).?;
    std.debug.assert(counts.len == 4);
    const expected_counts = &[_]usize{ 1, 1, 1, 0 };
    try std.testing.expectEqualSlices(usize, expected_counts, counts);
}

test "meter can create gauge instrument and record value without attributes" {
    const mp = try MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var gauge = try meter.createGauge(i16, .{ .name = "a-gauge" });

    try gauge.record(42, null);
    try gauge.record(-42, null);
    std.debug.assert(gauge.values.count() == 1);
    std.debug.assert(gauge.values.get(0) == -42);
}
