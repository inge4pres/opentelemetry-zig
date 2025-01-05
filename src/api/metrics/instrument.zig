const std = @import("std");

const spec = @import("spec.zig");
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const DataPoint = @import("measurement.zig").DataPoint;
const MeasurementsData = @import("measurement.zig").MeasurementsData;

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

const instrumentData = union(enum) {
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

/// Instrument is a container of all supported instrument types.
/// When the Meter wants to create a new instrument, it calls the new() function.
pub const Instrument = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    kind: Kind,
    opts: InstrumentOptions,
    data: instrumentData,

    pub fn new(kind: Kind, opts: InstrumentOptions, allocator: std.mem.Allocator) !*Self {
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

    pub fn getInstrumentsData(self: Self, allocator: std.mem.Allocator) !MeasurementsData {
        switch (self.data) {
            inline else => |i| {
                return i.measurementsData(allocator);
            },
        }
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
    advisory: ?[]Attribute = null,

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

        /// Record the measurements for the counter.
        /// The list of measurements will be used when reading the data during a collection cycle.
        /// The list is cleared after each collection cycle.
        measurements: std.ArrayList(DataPoint(T)),

        fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .measurements = std.ArrayList(DataPoint(T)).init(allocator),
                .allocator = allocator,
            };
        }

        fn deinit(self: *Self) void {
            for (self.measurements.items) |m| {
                if (m.attributes) |attrs| {
                    self.allocator.free(attrs);
                }
            }
            self.measurements.deinit();
        }

        /// Add the given delta to the counter, using the provided attributes.
        pub fn add(self: *Self, delta: T, attributes: anytype) !void {
            const attrs = try Attributes.from(self.allocator, attributes);
            try self.measurements.append(DataPoint(T){ .value = delta, .attributes = attrs });
        }

        fn measurementsData(self: Self, allocator: std.mem.Allocator) !MeasurementsData {
            switch (T) {
                u16, u32, u64, i16, i32, i64 => {
                    var data = try allocator.alloc(DataPoint(i64), self.measurements.items.len);
                    for (self.measurements.items, 0..) |m, idx| {
                        data[idx] = .{ .attributes = m.attributes, .value = @intCast(m.value) };
                    }
                    return .{ .int = data };
                },
                else => unreachable,
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
        /// Keeps track of the recorded values for each set of attributes.
        /// The measurements are cleared after each collection cycle.
        dataPoints: std.ArrayList(DataPoint(T)),

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
                .dataPoints = std.ArrayList(DataPoint(T)).init(allocator),
                .counts = std.AutoHashMap(?[]Attribute, usize).init(allocator),
                .buckets = buckets,
                .bucket_counts = std.AutoHashMap(?[]Attribute, []usize).init(allocator),
            };
        }

        fn deinit(self: *Self) void {
            // Cleanup the arraylist or measures and their attributes.
            for (self.dataPoints.items) |m| {
                if (m.attributes) |attrs| {
                    self.allocator.free(attrs);
                }
            }
            self.dataPoints.deinit();
            // We don't need to free the counts or bucket_counts keys,
            // because the keys are pointers to the same optional
            // KeyValueList used in cumulative.
            self.counts.deinit();
            self.bucket_counts.deinit();
        }

        /// Add the given value to the histogram, using the provided attributes.
        pub fn record(self: *Self, value: T, attributes: anytype) !void {
            const attrs = try Attributes.from(self.allocator, attributes);
            try self.dataPoints.append(DataPoint(T){ .value = value, .attributes = attrs });

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

        fn measurementsData(self: Self, allocator: std.mem.Allocator) !MeasurementsData {
            switch (T) {
                u16, u32, u64, i16, i32, i64 => {
                    var data = try allocator.alloc(DataPoint(i64), self.dataPoints.items.len);
                    for (self.dataPoints.items, 0..) |m, idx| {
                        data[idx] = .{ .attributes = m.attributes, .value = @intCast(m.value) };
                    }
                    return .{ .int = data };
                },
                f32, f64 => {
                    var data = try allocator.alloc(DataPoint(f64), self.dataPoints.items.len);
                    for (self.dataPoints.items, 0..) |m, idx| {
                        data[idx] = .{ .attributes = m.attributes, .value = @floatCast(m.value) };
                    }
                    return .{ .double = data };
                },
                else => unreachable,
            }
        }
    };
}

pub fn Gauge(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        dataPoints: std.ArrayList(DataPoint(T)),

        fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .dataPoints = std.ArrayList(DataPoint(T)).init(allocator),
            };
        }

        fn deinit(self: *Self) void {
            for (self.dataPoints.items) |m| {
                if (m.attributes) |attrs| {
                    self.allocator.free(attrs);
                }
            }
            self.dataPoints.deinit();
        }

        /// Record the given value to the gauge, using the provided attributes.
        pub fn record(self: *Self, value: T, attributes: anytype) !void {
            const attrs = try Attributes.from(self.allocator, attributes);
            try self.dataPoints.append(DataPoint(T){ .value = value, .attributes = attrs });
        }

        fn measurementsData(self: Self, allocator: std.mem.Allocator) !MeasurementsData {
            switch (T) {
                i16, i32, i64 => {
                    var data = try allocator.alloc(DataPoint(i64), self.dataPoints.items.len);
                    for (self.dataPoints.items, 0..) |m, idx| {
                        data[idx] = .{ .attributes = m.attributes, .value = @intCast(m.value) };
                    }
                    return .{ .int = data };
                },
                f32, f64 => {
                    var data = try allocator.alloc(DataPoint(f64), self.dataPoints.items.len);
                    for (self.dataPoints.items, 0..) |m, idx| {
                        data[idx] = .{ .attributes = m.attributes, .value = @floatCast(m.value) };
                    }
                    return .{ .double = data };
                },
                else => unreachable,
            }
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
    std.debug.assert(counter.measurements.items.len == 1);
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

    std.debug.assert(counter.measurements.items.len == 2);
    std.debug.assert(counter.measurements.items[0].value == 100);
    std.debug.assert(counter.measurements.items[1].value == 1000);

    const val1: []const u8 = "some-value";
    const val2: []const u8 = "another-value";

    try counter.add(2, .{ "some-key", val1, "another-key", val2 });
    std.debug.assert(counter.measurements.items.len == 3);
    std.debug.assert(counter.measurements.items[2].value == 2);
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
    std.debug.assert(histogram.dataPoints.items.len == 3);

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
    std.debug.assert(histogram.dataPoints.items.len == 3);

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
    std.debug.assert(gauge.dataPoints.items.len == 2);
    std.debug.assert(gauge.dataPoints.pop().value == -42);
}

test "meter creates upDownCounter and stores value" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createUpDownCounter(i32, .{ .name = "up-down-counter" });

    try counter.add(10, .{});
    try counter.add(-5, .{});
    try counter.add(-4, .{});
    std.debug.assert(counter.measurements.items.len == 3);

    // Validate the number stored is correct.
    // Empty attributes produce a null key.
    var summed: i32 = 0;
    for (counter.measurements.items) |m| {
        summed += m.value;
    }
    std.debug.assert(summed == 1);

    try counter.add(1, .{ "some-key", @as(i64, 42) });

    std.debug.assert(counter.measurements.items.len == 4);
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

        const counter_value = instrument.data.Counter_u64.measurements.popOrNull() orelse unreachable;
        try std.testing.expectEqual(100, counter_value.value);
    } else {
        std.debug.panic("Counter {s} not found in meter {s} after creation", .{ name, meter.name });
    }
}

test "instrument fetches measurements from inner" {
    const mp = try MeterProvider.default();
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
        var measurements = try instrument.getInstrumentsData(std.testing.allocator);
        defer measurements.deinit(std.testing.allocator);

        std.debug.assert(measurements.int.len == 1);
        try std.testing.expectEqual(@as(i64, 100), measurements.int[0].value);
    } else {
        std.debug.panic("Counter {s} not found in meter {s} after creation", .{ name, meter.name });
    }
}
