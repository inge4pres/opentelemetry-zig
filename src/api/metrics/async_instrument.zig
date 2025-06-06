const std = @import("std");
const Kind = @import("instrument.zig").Kind;
const MeasurementsData = @import("measurement.zig").MeasurementsData;
const DataPoint = @import("measurement.zig").DataPoint;

const Attributes = @import("../../attributes.zig").Attributes;

/// An asynchronous instrument is a metric that reports measurements
/// when the metere is observed thourhg a callback.
pub const AsyncInstrument = @This();

/// Errors that can occur while observing measurements,
pub const MetricObserveError = error{
    /// The callback failed to observe the measurements.
    CallbackExecutionFailed,
    /// The callback returned a collection of data points whose type is not supported by the instrument.
    UnsupportedDataPointTypeReturnedByCallback,
    /// Two separate callbacks returned distinct collection of data points with different types.
    NonUniformMeasurementsDataType,
} || std.mem.Allocator.Error;

/// The context in which the measurements were observed.
/// This struct is used to pass additional data to the callback that observes the measurements.
pub const ObservedContext = struct {
    /// The context in which the measurements were observed.
    /// This can be used to pass additional data to the callback.
    context: ?*anyopaque = null,

    /// Returns a new ObservedContext with the given context.
    /// The context is expected to be a pointer to any type that the callback can use.
    pub fn from(inner: anytype) ObservedContext {
        return ObservedContext{ .context = @ptrCast(inner) };
    }

    pub fn into(self: ObservedContext, comptime T: type) ?*T {
        if (self.context) |c| {
            const o: *T = @ptrCast(@alignCast(c));
            return o;
        }
        return null;
    }
};

test ObservedContext {
    const test_alloc = std.testing.allocator;
    const gauges = struct {
        sensor_1: i64,
        sensor_2: i64,
    };
    const observer = struct {
        data: gauges,

        fn observe(ctx: ObservedContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData {
            const g = ctx.into(gauges);

            const temperatures = try allocator.alloc(DataPoint(i64), 2);
            temperatures[0] = try DataPoint(i64).new(allocator, g.?.sensor_1, .{ "sensorID", @as(u64, 0) });
            temperatures[1] = try DataPoint(i64).new(allocator, g.?.sensor_2, .{ "sensorID", @as(u64, 1) });
            return .{ .int = temperatures };
        }
    };

    var observation = gauges{ .sensor_1 = 42, .sensor_2 = -100 };

    const data = try observer.observe(
        ObservedContext.from(&observation),
        test_alloc,
    );
    defer {
        for (data.int) |*dp| dp.deinit(test_alloc);
        test_alloc.free(data.int);
    }
}

/// Defines the callback that can be used to observe measurements in Asynchronous Instruments.
/// The "context" parameter is used to pass any additional data needed for the observation.
/// Callers are expected to free up the memory for the returned MeasurementsData.
pub const ObserveMeasures = *const fn (context: ObservedContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData;

/// Returns an instance of an asynchronous instrument by Kind.
/// The type parameter determines the type of the counter: unsigned integers produce an instrument of Kind .ObservableCounter,
/// signed integers produce an instrument of Kind .ObservableUpDownCounter.
pub fn ObservableInstrument(K: Kind) type {
    switch (K) {
        .ObservableCounter, .ObservableGauge, .ObservableUpDownCounter => {
            return struct {
                const Self = @This();

                allocator: std.mem.Allocator,
                lock: std.Thread.Mutex = .{},
                /// List of functions that will produce data points when called.
                /// Functions are called by the Meter when it observes the instrument (e.g. when Metricreader collects metrics).
                callbacks: ?[]ObserveMeasures = null,
                context: ObservedContext,

                pub fn init(allocator: std.mem.Allocator, ctx: ?ObservedContext) Self {
                    return Self{
                        .allocator = allocator,
                        .context = ctx orelse .{},
                    };
                }

                pub fn deinit(self: *Self) void {
                    if (self.callbacks) |c| self.allocator.free(c);
                }

                /// Attaches a callback to the instrument.
                /// Of separate callbacks produce data points with equal attributes, only the last
                /// observation is kept, using the order of registration.
                /// All callbacks are expected to return a MeasurementsData with consistent type.
                /// If different callbacks return different types, an error is returned when observing them.
                pub fn registerCallback(self: *Self, callback: ObserveMeasures) !void {
                    self.lock.lock();
                    defer self.lock.unlock();

                    if (self.callbacks) |c| {
                        var new_callbacks = try self.allocator.alloc(ObserveMeasures, c.len + 1);
                        std.mem.copyForwards(ObserveMeasures, new_callbacks, c);
                        new_callbacks[c.len] = callback;
                        self.callbacks = new_callbacks;
                        self.allocator.free(c);
                    } else {
                        self.callbacks = try self.allocator.alloc(ObserveMeasures, 1);
                        self.callbacks.?[0] = callback;
                    }
                }

                fn observe(self: *Self, allocator: std.mem.Allocator) MetricObserveError!?MeasurementsData {
                    self.lock.lock();
                    defer self.lock.unlock();

                    if (self.callbacks) |c| {
                        var m = try allocator.alloc(MeasurementsData, c.len);
                        defer allocator.free(m);

                        for (c, 0..) |callback, idx| {
                            var result = try callback(self.context, allocator);
                            // If we encounter an error while observing, we need to clear the memory allocated for the current
                            // callback execution, as well as the previously allocated measurements.
                            // A failure in one callback affects all the others.
                            errdefer {
                                result.deinit(allocator);
                                for (m[0..idx]) |*mes| {
                                    mes.deinit(allocator);
                                }
                            }
                            // We need to ensure that all callbacks return the same type of data points,
                            // because we are merging them into a single MeasurementsData.
                            if (idx > 0) {
                                if (std.meta.activeTag(result) != std.meta.activeTag(m[idx - 1])) {
                                    return MetricObserveError.NonUniformMeasurementsDataType;
                                }
                            }
                            switch (result) {
                                .int, .double => {},
                                else => return MetricObserveError.UnsupportedDataPointTypeReturnedByCallback,
                            }
                            m[idx] = result;
                        }

                        // Join all data points from the callbacks into a single MeasurementsData.
                        // We need to find first the type of data points we are dealing with.
                        var uniqueData: MeasurementsData = m[0];
                        if (m.len > 1) {
                            for (1..m.len) |i| {
                                try uniqueData.join(m[i], allocator);
                            }
                        }

                        // De-duplicate data points with the same attributes.
                        try uniqueData.dedupByAttributes(allocator);

                        return uniqueData;
                    }
                    return null; // No callbacks registered, nothing to observe.
                }

                /// Observes the instrument and returns the measurements collected by the callbacks.
                /// Data points with the same attributes are de-duplicated keeping only the last one,
                /// by the order of callbacks registration.
                pub fn measurementsData(self: *Self, allocator: std.mem.Allocator) !MeasurementsData {
                    return try self.observe(allocator) orelse MeasurementsData{ .int = &.{} };
                }
            };
        },
        else => @compileError("Unsupported Kind for ObservableInstrument."),
    }
}

fn testCallback(_: ObservedContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData {
    const data = try allocator.alloc(DataPoint(i64), 1);
    data[0] = try DataPoint(i64).new(allocator, 42, .{});
    return .{ .int = data };
}

test ObservableInstrument {
    const allocator = std.testing.allocator;
    const instrument = try allocator.create(ObservableInstrument(.ObservableUpDownCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableUpDownCounter).init(allocator, null);
    defer instrument.deinit();

    try instrument.registerCallback(testCallback);
    try std.testing.expect(instrument.callbacks.?[0] == testCallback);
}

test "observable instrument with multiple callbacks" {
    const anotherCallback: ObserveMeasures = testCallback;

    const allocator = std.testing.allocator;
    const instrument = try allocator.create(ObservableInstrument(.ObservableGauge));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableGauge).init(allocator, null);
    defer instrument.deinit();

    try instrument.registerCallback(testCallback);
    try instrument.registerCallback(anotherCallback);

    try std.testing.expect(instrument.callbacks.?[0] == testCallback);
    try std.testing.expect(instrument.callbacks.?[1] == anotherCallback);
}

fn testCallbackWithAttrs(_: ObservedContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData {
    const data = try allocator.alloc(DataPoint(f64), 1);
    data[0] = try DataPoint(f64).new(allocator, 3.14, .{ "pi", true });
    return .{ .double = data };
}

test "observable instrument collects data" {
    const allocator = std.testing.allocator;
    const instrument = try allocator.create(ObservableInstrument(.ObservableCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableCounter).init(allocator, null);
    defer instrument.deinit();

    try instrument.registerCallback(testCallbackWithAttrs);
    try instrument.registerCallback(testCallbackWithAttrs);

    // We expect the data to be de-duplicated, so we should only have one data point.
    const data = try instrument.observe(allocator);
    defer {
        for (data.?.double) |*dp| dp.deinit(allocator);
        allocator.free(data.?.double);
    }
    // Only one data point should be returned, as both callbacks return the same data.
    try std.testing.expectEqual(1, data.?.double.len);
}

test "observable instrument fails to observe callbacks with different data types" {
    const allocator = std.testing.allocator;
    const instrument = try allocator.create(ObservableInstrument(.ObservableCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableCounter).init(allocator, null);
    defer instrument.deinit();
    try instrument.registerCallback(testCallback);
    try instrument.registerCallback(testCallbackWithAttrs);

    const result = instrument.observe(allocator);
    try std.testing.expectError(MetricObserveError.NonUniformMeasurementsDataType, result);
}

// The specification says:
// "Callback functions SHOULD NOT make duplicate observations (more than one Measurement with the same attributes) across all registered callbacks."
// Hence, we need to ensure that the observable instrument does not fetch duplicate data from multiple callbacks.
test "observable instrument de-duplicate datapoints when fetching" {
    const allocator = std.testing.allocator;
    const instrument = try allocator.create(ObservableInstrument(.ObservableGauge));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableGauge).init(allocator, null);
    defer instrument.deinit();

    try instrument.registerCallback(testCallbackWithAttrs);
    try instrument.registerCallback(testCallbackWithAttrs);

    // We expect the data to be de-duplicated, so we should only have one data point.
    const data = try instrument.measurementsData(allocator);
    defer allocator.free(data.double);
    defer for (data.double) |*dp| dp.deinit(allocator);

    try std.testing.expectEqual(1, data.double.len);
}

test "observable instrument e2e measurements with context" {
    const allocator = std.testing.allocator;

    const request = struct {
        const Self = @This();

        user: []const u8,
        counter: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

        fn incr(self: *Self) void {
            _ = self.counter.fetchAdd(1, .acq_rel);
        }

        fn testCallbackWithRequest(ctx: ObservedContext, alloc: std.mem.Allocator) MetricObserveError!MeasurementsData {
            const req = ctx.into(Self);
            if (req) |r| {
                r.incr();
                const data = try alloc.alloc(DataPoint(i64), 1);
                data[0] = try DataPoint(i64).new(alloc, r.counter.load(.monotonic), .{ "user", r.user });
                return .{ .int = data };
            }
            return MetricObserveError.CallbackExecutionFailed;
        }
    };

    const instrument = try allocator.create(ObservableInstrument(.ObservableUpDownCounter));
    defer allocator.destroy(instrument);

    var monitor = request{ .user = "test-user" };
    instrument.* = ObservableInstrument(.ObservableUpDownCounter).init(allocator, ObservedContext.from(&monitor));
    defer instrument.deinit();

    try instrument.registerCallback(request.testCallbackWithRequest);

    var data = try instrument.measurementsData(allocator);
    defer data.deinit(allocator);

    try std.testing.expectEqual(1, data.int.len);
}
