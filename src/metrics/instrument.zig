const std = @import("std");
const Attribute = @import("attributes.zig").Attribute;
const Attributes = @import("attributes.zig").Attributes;

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("../opentelemetry/proto/common/v1.pb.zig");
const pbmetrics = @import("../opentelemetry/proto/metrics/v1.pb.zig");
const pbutils = @import("../pbutils.zig");
const spec = @import("spec.zig");

pub const Kind = enum {
    Counter,
    UpDownCounter,
    Histogram,
    Gauge,

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            .Counter => "Counter",
            .UpDownCounter => "UpDownCounter",
            .Histogram => "Histogram",
            .Gauge => "Gauge",
        };
    }
};

const SupportedInstrument = union(enum) {
    Counter_u16: *Counter(u16),
    Counter_u32: *Counter(u32),
    Counter_u64: *Counter(u64),
    UpDownCounter_i16: *Counter(i16),
    UpDownCounter_i32: *Counter(i32),
    UpDownCounter_i64: *Counter(i64),
    Histogram_u16: *Histogram(u16),
    Histogram_u32: *Histogram(u32),
    Histogram_u64: *Histogram(u64),
    Histogram_f32: *Histogram(f32),
    Histogram_f64: *Histogram(f64),
    Gauge_i16: *Gauge(i16),
    Gauge_i32: *Gauge(i32),
    Gauge_i64: *Gauge(i64),
    Gauge_f32: *Gauge(f32),
    Gauge_f64: *Gauge(f64),
};

/// Instrument contains all supported instruments.
/// When the Meter wants to create a new instrument, it calls the Get() method.
pub const Instrument = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    kind: Kind,
    opts: InstrumentOptions,
    data: SupportedInstrument,

    pub fn Get(kind: Kind, opts: InstrumentOptions, allocator: std.mem.Allocator) !*Self {
        // Validate name, unit anddescription, optionally throwing an error if non conformant.
        // See https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-name-syntax
        try spec.validateInstrumentOptions(opts);
        const i = try allocator.create(Self);
        i.* = Self{
            .allocator = allocator,
            .kind = kind,
            .opts = opts,
            .data = undefined,
        };
        return i;
    }

    pub fn counter(self: *Self, comptime T: type) !*Counter(T) {
        const c = try self.allocator.create(Counter(T));
        c.* = Counter(T).init(self.allocator);
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

    pub fn upDownCounter(self: *Self, comptime T: type) !*Counter(T) {
        const c = try self.allocator.create(Counter(T));
        c.* = Counter(T).init(self.allocator);
        self.data = switch (T) {
            i16 => .{ .UpDownCounter_i16 = c },
            i32 => .{ .UpDownCounter_i32 = c },
            i64 => .{ .UpDownCounter_i64 = c },
            else => {
                std.debug.print("Unsupported Up Down counter value type: {s}\n", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return c;
    }

    pub fn histogram(self: *Self, comptime T: type) !*Histogram(T) {
        const h = try self.allocator.create(Histogram(T));
        h.* = try Histogram(T).init(self.allocator, self.opts.histogramOpts);
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

    pub fn gauge(self: *Self, comptime T: type) !*Gauge(T) {
        const g = try self.allocator.create(Gauge(T));
        g.* = Gauge(T).init(self.allocator);
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

    pub fn deinit(self: *Self) void {
        switch (self.data) {
            inline else => |i| {
                i.deinit();
                self.allocator.destroy(i);
            },
        }
        self.allocator.destroy(self);
    }
};

/// InstrumentOptions is used to configure the instrument.
/// Base instrument options are name, description and unit.
/// Kind is inferred from the concrete type of the instrument.
pub const InstrumentOptions = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    // Advisory parameters are in development, we don't support them yet, so we set to null.
    advisory: ?pbcommon.KeyValueList = null,

    histogramOpts: ?HistogramOptions = null,
};

/// HistogramOptions is used to configure the histogram instrument.
pub const HistogramOptions = struct {
    /// ExplicitBuckets is used to specify the bucket boundaries.
    /// Do not set to rely on the specification default buckets.
    explicitBuckets: ?[]const f64 = null,
    recordMinMax: bool = true,
};

/// A Counter is a monotonically increasing value used to record cumulative events.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#counter
pub fn Counter(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,

        // We should keep track of the current value of the counter for each unique comibination of attribute.
        // At the same time, we don't want to allocate memory for each attribute set that comes in.
        // So we store all the counters in a single array and keep track of the state of each counter.
        cumulative: std.AutoHashMap(?[]Attribute, T),

        fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .cumulative = std.AutoHashMap(?[]Attribute, T).init(allocator),
                .allocator = allocator,
            };
        }

        fn deinit(self: *Self) void {
            if (self.cumulative.count() > 0) {
                var keyIter = self.cumulative.keyIterator();
                while (keyIter.next()) |key| {
                    if (key.*) |k| {
                        self.allocator.free(k);
                    }
                }
            }
            self.cumulative.deinit();
        }

        /// Add the given delta to the counter, using the provided attributes.
        /// // FIXME we should use anonymous types to build the attributes.
        pub fn add(self: *Self, delta: T, attributes: anytype) !void {
            const attrs = try Attributes.from(self.allocator, attributes);
            if (self.cumulative.getEntry(attrs)) |c| {
                c.value_ptr.* += delta;
            } else {
                try self.cumulative.put(attrs, delta);
            }
        }
    };
}

/// A Histogram is used to sample observations and count them in pre-defined buckets.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#histogram
pub fn Histogram(comptime T: type) type {
    return struct {
        const Self = @This();
        // Define a maximum number of buckets that can be used to record measurements.
        const maxBuckets = 1024;

        allocator: std.mem.Allocator,

        options: HistogramOptions,
        // Keep track of the current value of the counter for each unique comibination of attribute.
        // At the same time, don't want allocate memory for each attribute set that comes in.
        // Store all the counters in a single array and keep track of the state of each counter.
        cumulative: std.AutoHashMap(?[]Attribute, T),

        // Keeps track of how many values are summed for each set of attributes.
        counts: std.AutoHashMap(?[]Attribute, usize),
        // Holds the counts of the values falling in each bucket for the histogram.
        // The buckets are defined by the user if explcitily provided, otherwise the default SDK specification
        // buckets are used.
        // Buckets are always defined as f64.
        buckets: []const f64,
        bucket_counts: std.AutoHashMap(?[]Attribute, []usize),
        min: ?T = null,
        max: ?T = null,

        fn init(allocator: std.mem.Allocator, options: ?HistogramOptions) !Self {
            // Use the default options if none are provided.
            const opts = options orelse HistogramOptions{};
            // Buckets are part of the options, so we validate them from there.
            const buckets = opts.explicitBuckets orelse spec.defaultHistogramBucketBoundaries;
            try spec.validateExplicitBuckets(buckets);

            return Self{
                .allocator = allocator,
                .options = opts,
                .cumulative = std.AutoHashMap(?[]Attribute, T).init(allocator),
                .counts = std.AutoHashMap(?[]Attribute, usize).init(allocator),
                .buckets = buckets,
                .bucket_counts = std.AutoHashMap(?[]Attribute, []usize).init(allocator),
            };
        }

        fn deinit(self: *Self) void {
            // Cleanup the cumulative hashmap and the keys.
            if (self.cumulative.count() > 0) {
                var keyIter = self.cumulative.keyIterator();
                while (keyIter.next()) |key1| {
                    if (key1.*) |k| {
                        self.allocator.free(k);
                    }
                }
            }
            self.cumulative.deinit();
            // We don't need to free the counts or bucket_counts keys,
            // because the keys are pointers to the same optional
            // KeyValueList used in cumulative.
            self.counts.deinit();
            self.bucket_counts.deinit();
        }

        /// Add the given value to the histogram, using the provided attributes.
        pub fn record(self: *Self, value: T, attributes: anytype) !void {
            const attrs = try Attributes.from(self.allocator, attributes);

            if (self.cumulative.getEntry(attrs)) |c| {
                c.value_ptr.* += value;
            } else {
                try self.cumulative.put(attrs, value);
            }
            // Find the value for the bucket that the value falls in.
            // If the value is greater than the last bucket, it goes in the last bucket.
            // If the value is less than the first bucket, it goes in the first bucket.
            // Otherwise, it goes in the bucket for which the boundary is greater than or equal the value.
            const bucketIdx = self.findBucket(value);
            if (self.bucket_counts.getEntry(attrs)) |bc| {
                bc.value_ptr.*[bucketIdx] += 1;
            } else {
                var counts = [_]usize{0} ** maxBuckets;
                counts[bucketIdx] = 1;
                try self.bucket_counts.put(attrs, counts[0..self.buckets.len]);
            }

            // Increment the count of values for the given attributes.
            if (self.counts.getEntry(attrs)) |c| {
                c.value_ptr.* += 1;
            } else {
                try self.counts.put(attrs, 1);
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
            const vf64: f64 = switch (T) {
                u16, u32, u64 => @as(f64, @floatFromInt(value)),
                f32, f64 => @as(f64, value),
                else => unreachable,
            };
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

        allocator: std.mem.Allocator,
        values: std.AutoHashMap(?[]Attribute, T),

        fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .values = std.AutoHashMap(?[]Attribute, T).init(allocator),
            };
        }

        fn deinit(self: *Self) void {
            if (self.values.count() > 0) {
                var keyIter = self.values.keyIterator();
                while (keyIter.next()) |key| {
                    if (key.*) |k| {
                        self.allocator.free(k);
                    }
                }
            }
            self.values.deinit();
        }

        /// Record the given value to the gauge, using the provided attributes.
        pub fn record(self: *Self, value: T, attributes: anytype) !void {
            const attrs = try Attributes.from(self.allocator, attributes);
            try self.values.put(attrs, value);
        }
    };
}

const MeterProvider = @import("meter.zig").MeterProvider;

test "meter can create counter instrument and record increase without attributes" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(u32, .{ .name = "a-counter" });

    try counter.add(10, .{});
    std.debug.assert(counter.cumulative.count() == 1);
}

test "meter can create counter instrument and record increase with attributes" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(u32, .{
        .name = "a-counter",
        .description = "a funny counter",
        .unit = "KiB",
    });

    try counter.add(100, .{});
    try counter.add(1000, .{});
    std.debug.assert(counter.cumulative.count() == 1);
    std.debug.assert(counter.cumulative.get(null).? == 1100);

    const val1: []const u8 = "some-value";
    const val2: []const u8 = "another-value";

    try counter.add(2, .{ "some-key", val1, "another-key", val2 });
    std.debug.assert(counter.cumulative.count() == 2);
}

test "meter can create histogram instrument and record value without explicit buckets" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "anything" });

    try histogram.record(1, .{});
    try histogram.record(5, .{});
    try histogram.record(15, .{});

    try std.testing.expectEqual(.{ 1, 15 }, .{ histogram.min.?, histogram.max.? });
    std.debug.assert(histogram.cumulative.count() == 1);
    const counts = histogram.bucket_counts.get(null).?;
    std.debug.assert(counts.len == spec.defaultHistogramBucketBoundaries.len);
    const expected_counts = &[_]usize{ 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(usize, expected_counts, counts);
}

test "meter can create histogram instrument and record value with explicit buckets" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "a-histogram", .histogramOpts = .{ .explicitBuckets = &.{ 1.0, 10.0, 100.0, 1000.0 } } });

    try histogram.record(1, .{});
    try histogram.record(5, .{});
    try histogram.record(15, .{});

    try std.testing.expectEqual(.{ 1, 15 }, .{ histogram.min.?, histogram.max.? });
    std.debug.assert(histogram.cumulative.count() == 1);
    const counts = histogram.bucket_counts.get(null).?;
    std.debug.assert(counts.len == 4);
    const expected_counts = &[_]usize{ 1, 1, 1, 0 };
    try std.testing.expectEqualSlices(usize, expected_counts, counts);
}

test "meter can create gauge instrument and record value without attributes" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var gauge = try meter.createGauge(i16, .{ .name = "a-gauge" });

    try gauge.record(42, .{});
    try gauge.record(-42, .{});
    std.debug.assert(gauge.values.count() == 1);
    std.debug.assert(gauge.values.get(null) == -42);
}

test "meter creates upDownCounter and stores value" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createUpDownCounter(i32, .{ .name = "up-down-counter" });

    try counter.add(10, .{});
    try counter.add(-5, .{});
    try counter.add(-4, .{});
    std.debug.assert(counter.cumulative.count() == 1);

    // Validate the number stored is correct.
    // Empty attributes produce a null key.
    if (counter.cumulative.get(null)) |c| {
        std.debug.assert(c == 1);
    } else {
        std.debug.panic("Counter not found", .{});
    }

    try counter.add(1, .{ "some-key", @as(i64, 42) });
    std.debug.assert(counter.cumulative.count() == 2);

    var iter = counter.cumulative.valueIterator();

    while (iter.next()) |v| {
        std.debug.assert(v.* == 1);
    }
}

test "instrument in meter and instrument in data are the same" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const name = "test-instrument";

    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var c = try meter.createCounter(u64, .{ .name = name });
    try c.add(100, .{});

    const id = try spec.instrumentIdentifier(
        std.testing.allocator,
        name,
        Kind.Counter.toString(),
        "",
        "",
    );
    defer std.testing.allocator.free(id);

    if (meter.instruments.get(id)) |instrument| {
        std.debug.assert(instrument.kind == Kind.Counter);

        const counter_value = instrument.data.Counter_u64.cumulative.get(null) orelse unreachable;
        try std.testing.expectEqual(100, counter_value);
    } else {
        std.debug.panic("Counter {s} not found in meter {s} after creation", .{ name, meter.name });
    }
}
