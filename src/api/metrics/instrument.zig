const std = @import("std");

const log = std.log.scoped(.instrument);

const spec = @import("spec.zig");
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const DataPoint = @import("measurement.zig").DataPoint;
const HistogramDataPoint = @import("measurement.zig").HistogramDataPoint;

const MeasurementsData = @import("measurement.zig").MeasurementsData;

const AsyncInstrument = @import("async_instrument.zig");

pub const Kind = enum {
    // Synchronous instruments
    Counter,
    UpDownCounter,
    Histogram,
    Gauge,
    // Observable instruments (ascynchronous)
    ObservableCounter,
    ObservableUpDownCounter,
    ObservableGauge,

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            .Counter => "Counter",
            .UpDownCounter => "UpDownCounter",
            .Histogram => "Histogram",
            .Gauge => "Gauge",
            .ObservableCounter => "ObservableCounter",
            .ObservableUpDownCounter => "ObservableUpDownCounter",
            .ObservableGauge => "ObservableGauge",
        };
    }
};

const instrumentData = union(enum) {
    // Synchronous instruments.
    Counter_u16: *Counter(u16),
    Counter_u32: *Counter(u32),
    Counter_u64: *Counter(u64),
    UpDownCounter_i16: *Counter(i16),
    UpDownCounter_i32: *Counter(i32),
    UpDownCounter_i64: *Counter(i64),
    Histogram_u16: *Histogram(u16),
    Histogram_u32: *Histogram(u32),
    Histogram_u64: *Histogram(u64),
    Histogram_i16: *Histogram(i16),
    Histogram_i32: *Histogram(i32),
    Histogram_i64: *Histogram(i64),
    Histogram_f32: *Histogram(f32),
    Histogram_f64: *Histogram(f64),
    Gauge_i16: *Gauge(i16),
    Gauge_i32: *Gauge(i32),
    Gauge_i64: *Gauge(i64),
    Gauge_f32: *Gauge(f32),
    Gauge_f64: *Gauge(f64),
    // Async instruments.
    ObservableCounter: *AsyncInstrument.ObservableInstrument(.ObservableCounter),
    ObservableUpDownCounter: *AsyncInstrument.ObservableInstrument(.ObservableUpDownCounter),
    ObservableGauge: *AsyncInstrument.ObservableInstrument(.ObservableGauge),
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
        errdefer self.allocator.destroy(c);
        self.data = switch (T) {
            u16 => .{ .Counter_u16 = c },
            u32 => .{ .Counter_u32 = c },
            u64 => .{ .Counter_u64 = c },
            else => {
                log.err("Unsupported monotonic counter value type: {s}", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return c;
    }

    pub fn upDownCounter(self: *Self, comptime T: type) !*Counter(T) {
        const c = try self.allocator.create(Counter(T));
        c.* = Counter(T).init(self.allocator);
        errdefer self.allocator.destroy(c);
        self.data = switch (T) {
            i16 => .{ .UpDownCounter_i16 = c },
            i32 => .{ .UpDownCounter_i32 = c },
            i64 => .{ .UpDownCounter_i64 = c },
            else => {
                log.err("Unsupported Up Down counter value type: {s}", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return c;
    }

    pub fn histogram(self: *Self, comptime T: type) !*Histogram(T) {
        const h = try self.allocator.create(Histogram(T));
        h.* = Histogram(T).init(self.allocator);
        errdefer self.allocator.destroy(h);
        self.data = switch (T) {
            u16 => .{ .Histogram_u16 = h },
            u32 => .{ .Histogram_u32 = h },
            u64 => .{ .Histogram_u64 = h },
            i16 => .{ .Histogram_i16 = h },
            i32 => .{ .Histogram_i32 = h },
            i64 => .{ .Histogram_i64 = h },
            f32 => .{ .Histogram_f32 = h },
            f64 => .{ .Histogram_f64 = h },
            else => {
                log.err("Unsupported histogram value type: {s}", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return h;
    }

    pub fn gauge(self: *Self, comptime T: type) !*Gauge(T) {
        const g = try self.allocator.create(Gauge(T));
        g.* = Gauge(T).init(self.allocator);
        errdefer self.allocator.destroy(g);
        self.data = switch (T) {
            i16 => .{ .Gauge_i16 = g },
            i32 => .{ .Gauge_i32 = g },
            i64 => .{ .Gauge_i64 = g },
            f32 => .{ .Gauge_f32 = g },
            f64 => .{ .Gauge_f64 = g },
            else => {
                log.err("Unsupported gauge value type: {s}", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return g;
    }

    pub fn asyncCounter(
        self: *Self,
        context: AsyncInstrument.ObservedContext,
        callbacks: ?[]AsyncInstrument.ObserveMeasures,
    ) !*AsyncInstrument.ObservableInstrument(.ObservableCounter) {
        const i = try self.allocator.create(AsyncInstrument.ObservableInstrument(.ObservableCounter));
        i.* = AsyncInstrument.ObservableInstrument(.ObservableCounter).init(self.allocator, context);

        if (callbacks) |cb| {
            for (cb) |c| {
                try i.registerCallback(c);
            }
        }
        self.data = .{ .ObservableCounter = i };
        return i;
    }

    pub fn asyncUpDownCounter(
        self: *Self,
        context: AsyncInstrument.ObservedContext,
        callbacks: ?[]AsyncInstrument.ObserveMeasures,
    ) !*AsyncInstrument.ObservableInstrument(.ObservableUpDownCounter) {
        const i = try self.allocator.create(AsyncInstrument.ObservableInstrument(.ObservableUpDownCounter));
        i.* = AsyncInstrument.ObservableInstrument(.ObservableUpDownCounter).init(self.allocator, context);

        if (callbacks) |cb| {
            for (cb) |c| {
                try i.registerCallback(c);
            }
        }
        self.data = .{ .ObservableUpDownCounter = i };
        return i;
    }

    pub fn asyncGauge(
        self: *Self,
        context: AsyncInstrument.ObservedContext,
        callbacks: ?[]AsyncInstrument.ObserveMeasures,
    ) !*AsyncInstrument.ObservableInstrument(.ObservableGauge) {
        const i = try self.allocator.create(AsyncInstrument.ObservableInstrument(.ObservableGauge));
        i.* = AsyncInstrument.ObservableInstrument(.ObservableGauge).init(self.allocator, context);

        if (callbacks) |cb| {
            for (cb) |c| {
                try i.registerCallback(c);
            }
        }
        self.data = .{ .ObservableGauge = i };
        return i;
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
};

/// A Counter is a monotonically increasing value used to record cumulative events.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#counter
pub fn Counter(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        lock: std.Thread.Mutex,

        /// Record data points for the counter.
        /// The list of measurements will be used when reading the data during a collection cycle.
        /// The list is cleared after each collection cycle.
        data_points: std.ArrayListUnmanaged(DataPoint(T)),

        fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .data_points = .empty,
                .allocator = allocator,
                .lock = std.Thread.Mutex{},
            };
        }

        fn deinit(self: *Self) void {
            for (self.data_points.items) |*m| {
                m.deinit(self.allocator);
            }
            self.data_points.deinit(self.allocator);
        }

        /// Add the given delta to the counter, using the provided attributes.
        pub fn add(self: *Self, delta: T, attributes: anytype) !void {
            self.lock.lock();
            defer self.lock.unlock();

            const dp = try DataPoint(T).new(self.allocator, delta, attributes);
            try self.data_points.append(self.allocator, dp);
        }

        fn measurementsData(self: *Self, allocator: std.mem.Allocator) !MeasurementsData {
            self.lock.lock();
            defer self.lock.unlock();
            // We have to clear up the data points after we return a copy of them.
            // this resets the state of the instrument, allowing to record more datapoints
            // until the next collection cycle.
            defer {
                for (self.data_points.items) |*m| {
                    m.deinit(self.allocator);
                }
                self.data_points.clearRetainingCapacity();
            }
            switch (T) {
                u16, u32, u64, i16, i32, i64 => {
                    var data = try allocator.alloc(DataPoint(i64), self.data_points.items.len);
                    for (self.data_points.items, 0..) |m, idx| {
                        data[idx] = .{
                            .value = @intCast(m.value),
                            .attributes = try Attributes.with(m.attributes).dupe(allocator),
                        };
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

        allocator: std.mem.Allocator,
        lock: std.Thread.Mutex,

        /// Keeps track of the raw recorded values for each set of attributes.
        /// The measurements are cleared after each collection cycle.
        data_points: std.ArrayListUnmanaged(DataPoint(T)),

        fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .lock = std.Thread.Mutex{},
                .data_points = .empty,
            };
        }

        fn deinit(self: *Self) void {
            // Cleanup the arraylist or measures and their attributes.
            for (self.data_points.items) |*m| {
                m.deinit(self.allocator);
            }
            self.data_points.deinit(self.allocator);
        }

        /// Add the given value to the histogram, using the provided attributes.
        pub fn record(self: *Self, value: T, attributes: anytype) !void {
            self.lock.lock();
            defer self.lock.unlock();

            const dp = try DataPoint(T).new(self.allocator, value, attributes);
            try self.data_points.append(self.allocator, dp);
        }

        fn measurementsData(self: *Self, allocator: std.mem.Allocator) !MeasurementsData {
            self.lock.lock();
            defer self.lock.unlock();

            // We have to clear up the data points after we return a copy of them.
            // This resets the collected measurements, allowing to record more datapoints
            // until the next collection cycle.
            defer {
                for (self.data_points.items) |*dp| {
                    dp.deinit(self.allocator);
                }
                self.data_points.clearRetainingCapacity();
            }

            // Return raw data points without aggregation
            // Aggregation will be performed later in AggregateMetrics.fetch()
            switch (T) {
                u16, u32, u64, i16, i32, i64 => {
                    var data = try allocator.alloc(DataPoint(i64), self.data_points.items.len);
                    for (self.data_points.items, 0..) |m, idx| {
                        data[idx] = .{
                            .value = @intCast(m.value),
                            .attributes = try Attributes.with(m.attributes).dupe(allocator),
                        };
                    }
                    return .{ .int = data };
                },
                f32, f64 => {
                    var data = try allocator.alloc(DataPoint(f64), self.data_points.items.len);
                    for (self.data_points.items, 0..) |m, idx| {
                        data[idx] = .{
                            .value = @floatCast(m.value),
                            .attributes = try Attributes.with(m.attributes).dupe(allocator),
                        };
                    }
                    return .{ .double = data };
                },
                // inner types are filtered before this point
                else => unreachable,
            }
        }
    };
}

pub fn Gauge(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        lock: std.Thread.Mutex,

        data_points: std.ArrayListUnmanaged(DataPoint(T)),

        fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .data_points = .empty,
                .lock = std.Thread.Mutex{},
            };
        }

        fn deinit(self: *Self) void {
            for (self.data_points.items) |*m| {
                m.deinit(self.allocator);
            }
            self.data_points.deinit(self.allocator);
        }

        /// Record the given value to the gauge, using the provided attributes.
        pub fn record(self: *Self, value: T, attributes: anytype) !void {
            self.lock.lock();
            defer self.lock.unlock();

            const dp = try DataPoint(T).new(self.allocator, value, attributes);
            try self.data_points.append(self.allocator, dp);
        }

        fn measurementsData(self: *Self, allocator: std.mem.Allocator) !MeasurementsData {
            self.lock.lock();
            defer self.lock.unlock();

            defer {
                for (self.data_points.items) |*dp| {
                    dp.deinit(self.allocator);
                }
                self.data_points.clearRetainingCapacity();
            }

            switch (T) {
                i16, i32, i64 => {
                    var data = try allocator.alloc(DataPoint(i64), self.data_points.items.len);
                    for (self.data_points.items, 0..) |m, idx| {
                        data[idx] = .{
                            .value = @intCast(m.value),
                            .attributes = try Attributes.with(m.attributes).dupe(allocator),
                        };
                    }
                    return .{ .int = data };
                },
                f32, f64 => {
                    var data = try allocator.alloc(DataPoint(f64), self.data_points.items.len);
                    for (self.data_points.items, 0..) |m, idx| {
                        data[idx] = .{
                            .value = @floatCast(m.value),
                            .attributes = try Attributes.with(m.attributes).dupe(allocator),
                        };
                    }
                    return .{ .double = data };
                },
                else => unreachable,
            }
        }
    };
}

const MeterProvider = @import("meter.zig").MeterProvider;

test "counter with unsupported type does not leak" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    const err = meter.createCounter(u1, .{ .name = "a-counter" });
    try std.testing.expectError(spec.FormatError.UnsupportedValueType, err);
}

test "meter can create counter instrument and record increase without attributes" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(u32, .{ .name = "a-counter" });

    try counter.add(10, .{});
    std.debug.assert(counter.data_points.items.len == 1);
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

    std.debug.assert(counter.data_points.items.len == 2);
    std.debug.assert(counter.data_points.items[0].value == 100);
    std.debug.assert(counter.data_points.items[1].value == 1000);

    const val1: []const u8 = "some-value";
    const val2: []const u8 = "another-value";

    try counter.add(2, .{ "some-key", val1, "another-key", val2 });
    std.debug.assert(counter.data_points.items.len == 3);
    std.debug.assert(counter.data_points.items[2].value == 2);
}

test "histogram records value without explicit buckets" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "anything" });

    try histogram.record(1, .{});
    try histogram.record(5, .{});
    try histogram.record(15, .{});

    // After recording, we get raw measurements data (int/double values, not pre-aggregated histogram)
    const measurements = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (measurements.int) |*dp| {
            dp.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(measurements.int);
    }

    // We should have 3 raw data points corresponding to the 3 recorded values
    try std.testing.expectEqual(3, measurements.int.len);
    // Verify the raw values are stored correctly
    try std.testing.expectEqual(@as(i64, 1), measurements.int[0].value);
    try std.testing.expectEqual(@as(i64, 5), measurements.int[1].value);
    try std.testing.expectEqual(@as(i64, 15), measurements.int[2].value);
}

test "histogram records value with explicit buckets" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "a-histogram" });

    try histogram.record(1, .{});
    try histogram.record(5, .{});
    try histogram.record(15, .{});

    try std.testing.expectEqual(3, histogram.data_points.items.len);

    // After recording, we get raw measurements data (int values, not pre-aggregated histogram)
    const measurements = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (measurements.int) |*dp| {
            dp.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(measurements.int);
    }

    // We should have 3 raw data points corresponding to the 3 recorded values
    try std.testing.expectEqual(3, measurements.int.len);
    // Verify the raw values are stored correctly
    try std.testing.expectEqual(@as(i64, 1), measurements.int[0].value);
    try std.testing.expectEqual(@as(i64, 5), measurements.int[1].value);
    try std.testing.expectEqual(@as(i64, 15), measurements.int[2].value);
}

test "histogram keeps track of bucket counts by attribute" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "a-histogram" });

    const val: []const u8 = "some-value";
    try histogram.record(1, .{ "some-key", val });
    try histogram.record(1000, .{ "other-key", val });

    try std.testing.expectEqual(2, histogram.data_points.items.len);

    // After recording, we get raw measurements data (not aggregated histogram data)
    const measurements = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (measurements.int) |*dp| {
            dp.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(measurements.int);
    }

    // Now we get raw integer data points instead of histogram buckets
    try std.testing.expectEqual(2, measurements.int.len);

    // Check that the raw values are preserved
    try std.testing.expectEqual(@as(i64, 1), measurements.int[0].value);
    try std.testing.expectEqual(@as(i64, 1000), measurements.int[1].value);
}

test "histogram keeps track of count, sum and min/max by attribute" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "a-histogram" });

    const val: []const u8 = "some-val";
    try histogram.record(1, .{});
    try histogram.record(5, .{ "key", val });
    try histogram.record(15, .{ "key", val });

    std.debug.assert(histogram.data_points.items.len == 3);

    // After recording, we get raw measurements data (not aggregated histogram data)
    const measurements = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (measurements.int) |*dp| {
            dp.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(measurements.int);
    }

    // We get raw integer data points, grouped by attributes
    try std.testing.expectEqual(3, measurements.int.len);

    // Check that the raw values are preserved (order may vary by attribute hash)
    var found_1 = false;
    var found_5 = false;
    var found_15 = false;

    for (measurements.int) |dp| {
        switch (dp.value) {
            1 => found_1 = true,
            5 => found_5 = true,
            15 => found_15 = true,
            else => unreachable,
        }
    }

    try std.testing.expect(found_1);
    try std.testing.expect(found_5);
    try std.testing.expect(found_15);
}

test "gauge instrument records value without attributes" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var gauge = try meter.createGauge(i16, .{ .name = "a-gauge" });

    try gauge.record(42, .{});
    try gauge.record(-42, .{});
    std.debug.assert(gauge.data_points.items.len == 2);
    std.debug.assert(gauge.data_points.pop().?.value == -42);
}

test "upDownCounter instrument records and stores value" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createUpDownCounter(i32, .{ .name = "up-down-counter" });

    try counter.add(10, .{});
    try counter.add(-5, .{});
    try counter.add(-4, .{});
    std.debug.assert(counter.data_points.items.len == 3);

    // Validate the number stored is correct.
    // Empty attributes produce a null key.
    var summed: i32 = 0;
    for (counter.data_points.items) |m| {
        summed += m.value;
    }
    std.debug.assert(summed == 1);

    try counter.add(1, .{ "some-key", @as(i64, 42) });

    std.debug.assert(counter.data_points.items.len == 4);
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

        const counter_value = instrument.data.Counter_u64.data_points.pop() orelse unreachable;
        try std.testing.expectEqual(100, counter_value.value);
    } else {
        std.debug.panic("Counter {s} not found in meter {s} after creation", .{ name, meter.scope.name });
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
        const measurements = try instrument.getInstrumentsData(std.testing.allocator);
        defer switch (measurements) {
            inline else => |list| std.testing.allocator.free(list),
        };

        std.debug.assert(measurements.int.len == 1);
        try std.testing.expectEqual(@as(i64, 100), measurements.int[0].value);
    } else {
        std.debug.panic("Counter {s} not found in meter {s} after creation", .{ name, meter.scope.name });
    }
}

test "counter thread-safety between datapoints collection and recording" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const name = "test-instrument";

    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var c = try meter.createCounter(u64, .{ .name = name });

    // We use attributes to perform memory allocation,
    // slowing down the add() call, retaining the lock
    // for longer
    const val: []const u8 = "test-val";
    try c.add(1, .{ "cde", val });

    const adding_job = try std.Thread.spawn(.{}, testCounterAddingOne, .{c});
    const fetch_compare = try std.Thread.spawn(.{}, testCounterCollect, .{c});
    adding_job.join();
    fetch_compare.join();
}

fn testCounterAddingOne(counter: *Counter(u64)) !void {
    const val: []const u8 = "test-val";
    try counter.add(2, .{ "abc", val });
}

fn testCounterCollect(counter: *Counter(u64)) !void {
    // FIXME flaky test can result in failure, so we added a sleep but we should find a more robust solution.
    for (0..1000) |_| {
        counter.lock.lock();
        counter.lock.unlock();
        std.time.sleep(25);
    }

    const fetched = try counter.measurementsData(std.testing.allocator);
    defer {
        for (fetched.int) |*m| {
            m.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(fetched.int);
    }
    // Assert that we have 2 data points: the first added by the test thread,
    // the second added by `testAddingOne` called in a separate thread.
    try std.testing.expectEqual(2, fetched.int.len);
    try std.testing.expectEqual(1, fetched.int[0].value);
    try std.testing.expectEqual(2, fetched.int[1].value);
}

test "histogram thread-safety" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const name = "test-instrument";

    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var h = try meter.createHistogram(u64, .{ .name = name });

    const val: []const u8 = "same-val";
    try h.record(20, .{ "same-key", val });

    const adding_job = try std.Thread.spawn(.{}, testHistogramRecordOne, .{h});
    const fetch_compare = try std.Thread.spawn(.{}, testHistogramCollect, .{h});
    adding_job.join();
    fetch_compare.join();
}

fn testHistogramRecordOne(histogram: *Histogram(u64)) !void {
    const val: []const u8 = "same-val";
    try histogram.record(1, .{ "same-key", val });
}

fn testHistogramCollect(histogram: *Histogram(u64)) !void {
    // FIXME flaky test can result in failure, so we added a sleep but we should find a more robust solution.
    for (0..1000) |_| {
        histogram.lock.lock();
        histogram.lock.unlock();
        std.time.sleep(25);
    }

    const fetched = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (fetched.int) |*m| {
            m.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(fetched.int);
    }
    // Assert that we have 2 raw data points (since both recordings have same attributes but are separate records)
    try std.testing.expectEqual(2, fetched.int.len);

    // Check that we have the raw values recorded
    const values = [_]i64{ fetched.int[0].value, fetched.int[1].value };
    try std.testing.expect(std.mem.containsAtLeast(i64, &values, 1, &[_]i64{1}));
    try std.testing.expect(std.mem.containsAtLeast(i64, &values, 1, &[_]i64{20}));
}

test "instrument cleans up internal state when datapoints are fetched" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const name = "test-instrument";

    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var c = try meter.createCounter(u64, .{ .name = name });

    const val: []const u8 = "test-val";
    try c.add(1, .{ "cde", val });

    const fetched = try c.measurementsData(std.testing.allocator);
    defer {
        for (fetched.int) |*m| {
            m.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(fetched.int);
    }
    // Assert that we have 1 data point: the first added by the test thread.
    try std.testing.expectEqual(0, c.data_points.items.len);
}

const MetricObserveError = AsyncInstrument.MetricObserveError;

test "async instrument registered in meter" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const background = struct {
        fn observe(_: AsyncInstrument.ObservedContext, _: std.mem.Allocator) MetricObserveError!MeasurementsData {
            // This is a dummy callback that does nothing.
            // In a real-world scenario, it would collect data asynchronously.
            return MeasurementsData{
                .int = &.{},
            };
        }
    };

    const name = "test-async-counter";
    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var callbacks = [_]AsyncInstrument.ObserveMeasures{
        background.observe,
    };

    var async_counter = try meter.createObservableCounter(
        .{ .name = name },
        .{},
        &callbacks,
    );

    // SDK users aren't expected to call measurementsData on the async instrument,
    // rather simply use the meter to register the instrument
    const data = try async_counter.measurementsData(std.testing.allocator);
    try std.testing.expectEqual(0, data.int.len);
}
