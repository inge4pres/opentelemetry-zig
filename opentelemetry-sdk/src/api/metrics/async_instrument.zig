const std = @import("std");
const clock = @import("clock");

const Kind = @import("instrument.zig").Kind;
const MeasurementsData = @import("measurement.zig").MeasurementsData;
const ExemplarFilter = @import("../../sdk/metrics/exemplar.zig").ExemplarFilter;

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
                io: std.Io,
                lock: std.Io.Mutex = .init,
                /// List of functions that will produce data points when called.
                /// Functions are called by the Meter when it observes the instrument (e.g. when Metricreader collects metrics).
                callbacks: std.ArrayList(ObserveMeasures) = .empty,
                context: ObservedContext,
                exemplar_filter: ExemplarFilter = .trace_based,
                collection_start_ns: u64 = 0,

                pub fn init(allocator: std.mem.Allocator, io: std.Io, ctx: ?ObservedContext) Self {
                    return Self{
                        .allocator = allocator,
                        .io = io,
                        .callbacks = .empty,
                        .context = ctx orelse .{},
                        .collection_start_ns = @intCast(clock.nanoTimestamp()),
                    };
                }

                pub fn deinit(self: *Self) void {
                    self.callbacks.deinit(self.allocator);
                }

                /// Attaches a callback to the instrument.
                /// Of separate callbacks produce data points with equal attributes, only the last
                /// observation is kept, using the order of registration.
                /// All callbacks are expected to return a MeasurementsData with consistent type.
                /// If different callbacks return different types, an error is returned when observing them.
                pub fn registerCallback(self: *Self, callback: ObserveMeasures) !void {
                    self.lock.lockUncancelable(self.io);
                    defer self.lock.unlock(self.io);

                    try self.callbacks.append(self.allocator, callback);
                }

                /// Removes a previously registered callback from the instrument.
                /// If the callback was not found, this is a no-op and returns false.
                /// Returns true if the callback was found and successfully removed.
                pub fn unregisterCallback(self: *Self, callback: ObserveMeasures) bool {
                    self.lock.lockUncancelable(self.io);
                    defer self.lock.unlock(self.io);

                    for (self.callbacks.items, 0..) |cb, idx| {
                        if (cb == callback) {
                            _ = self.callbacks.orderedRemove(idx);
                            return true;
                        }
                    }
                    return false;
                }

                fn observe(self: *Self, allocator: std.mem.Allocator) MetricObserveError!?MeasurementsData {
                    self.lock.lockUncancelable(self.io);
                    defer self.lock.unlock(self.io);

                    if (self.callbacks.items.len > 0) {
                        const c = self.callbacks.items;
                        if (c.len == 0) return null;
                        const m = try allocator.alloc(MeasurementsData, c.len);
                        var initialized: usize = 0;
                        defer {
                            for (m[0..initialized]) |*data| data.deinit(allocator);
                            allocator.free(m);
                        }
                        for (c, 0..) |callback, idx| {
                            var result = try callback(self.context, allocator);
                            errdefer result.deinit(allocator);
                            if (idx > 0 and std.meta.activeTag(result) != std.meta.activeTag(m[0]))
                                return MetricObserveError.NonUniformMeasurementsDataType;
                            switch (result) {
                                inline .int, .double => |points| {
                                    // A callback observes all its values at one logical instant.
                                    var observed_at: ?u64 = null;
                                    for (points) |*point| {
                                        try point.captureExemplar(allocator, self.exemplar_filter);
                                        if (point.exemplar_candidate) |*sample| {
                                            if (observed_at == null) observed_at = sample.time_ns;
                                            sample.time_ns = observed_at.?;
                                        }
                                    }
                                },
                                else => return MetricObserveError.UnsupportedDataPointTypeReturnedByCallback,
                            }
                            m[idx] = result;
                            initialized += 1;
                        }
                        var uniqueData = m[0];
                        m[0] = .{ .int = &.{} };
                        errdefer uniqueData.deinit(allocator);
                        for (m[1..]) |*data| {
                            try uniqueData.join(data.*, allocator);
                            data.* = .{ .int = &.{} };
                        }
                        try uniqueData.dedupByAttributes(allocator);
                        // Observation and its collection cut share the same lock.
                        const collection_time: u64 = @intCast(clock.nanoTimestamp());
                        switch (uniqueData) {
                            inline else => |points| for (points) |*point| {
                                point.timestamps = .{ .start_time_ns = self.collection_start_ns, .time_ns = collection_time };
                            },
                        }
                        self.collection_start_ns = collection_time;
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
    const io = std.testing.io;
    const instrument = try allocator.create(ObservableInstrument(.ObservableUpDownCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableUpDownCounter).init(allocator, io, null);
    defer instrument.deinit();

    try instrument.registerCallback(testCallback);
    try std.testing.expect(instrument.callbacks.items[0] == testCallback);
}

test "observable instrument with multiple callbacks" {
    const anotherCallback: ObserveMeasures = testCallback;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const instrument = try allocator.create(ObservableInstrument(.ObservableGauge));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableGauge).init(allocator, io, null);
    defer instrument.deinit();

    try instrument.registerCallback(testCallback);
    try instrument.registerCallback(anotherCallback);

    try std.testing.expect(instrument.callbacks.items[0] == testCallback);
    try std.testing.expect(instrument.callbacks.items[1] == anotherCallback);
}

fn testCallbackWithAttrs(_: ObservedContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData {
    const data = try allocator.alloc(DataPoint(f64), 1);
    data[0] = try DataPoint(f64).new(allocator, 3.14, .{ "pi", true });
    return .{ .double = data };
}

test "observable instrument collects data" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const instrument = try allocator.create(ObservableInstrument(.ObservableCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableCounter).init(allocator, io, null);
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
    const io = std.testing.io;
    const instrument = try allocator.create(ObservableInstrument(.ObservableCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableCounter).init(allocator, io, null);
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
    const io = std.testing.io;
    const instrument = try allocator.create(ObservableInstrument(.ObservableGauge));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableGauge).init(allocator, io, null);
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
    const io = std.testing.io;

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
    instrument.* = ObservableInstrument(.ObservableUpDownCounter).init(allocator, io, ObservedContext.from(&monitor));
    defer instrument.deinit();

    try instrument.registerCallback(request.testCallbackWithRequest);

    var data = try instrument.measurementsData(allocator);
    defer data.deinit(allocator);

    try std.testing.expectEqual(1, data.int.len);
}

test "observable instrument unregisterCallback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const instrument = try allocator.create(ObservableInstrument(.ObservableCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableCounter).init(allocator, io, null);
    defer instrument.deinit();

    // Unregistering when no callbacks exist returns false
    try std.testing.expect(!instrument.unregisterCallback(testCallback));

    // Register a callback
    try instrument.registerCallback(testCallback);
    try std.testing.expectEqual(@as(usize, 1), instrument.callbacks.items.len);

    // Unregister the callback
    try std.testing.expect(instrument.unregisterCallback(testCallback));
    try std.testing.expectEqual(@as(usize, 0), instrument.callbacks.items.len);

    // Unregistering again returns false
    try std.testing.expect(!instrument.unregisterCallback(testCallback));

    // Test with multiple callbacks: register 3 callbacks and remove the middle one
    const dummyCallback: ObserveMeasures = testCallbackWithAttrs;
    try instrument.registerCallback(testCallback);
    try instrument.registerCallback(dummyCallback);
    try instrument.registerCallback(testCallback);

    try std.testing.expectEqual(@as(usize, 3), instrument.callbacks.items.len);

    // Remove dummyCallback
    try std.testing.expect(instrument.unregisterCallback(dummyCallback));
    try std.testing.expectEqual(@as(usize, 2), instrument.callbacks.items.len);
    try std.testing.expect(instrument.callbacks.items[0] == testCallback);
    try std.testing.expect(instrument.callbacks.items[1] == testCallback);

    // Unregistering a non-present callback returns false and leaves list intact
    try std.testing.expect(!instrument.unregisterCallback(dummyCallback));
    try std.testing.expectEqual(@as(usize, 2), instrument.callbacks.items.len);
}

test "observable instrument unregisterCallback with failing allocator cleanup" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    const io = std.testing.io;

    const instrument = try allocator.create(ObservableInstrument(.ObservableCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableCounter).init(allocator, io, null);
    defer instrument.deinit();

    try instrument.registerCallback(testCallback);
    const dummyCallback: ObserveMeasures = testCallbackWithAttrs;
    try instrument.registerCallback(dummyCallback);

    // Disallow any further allocations
    failing.fail_index = failing.alloc_index;

    // Unregistering should not require allocation and should preserve capacity
    try std.testing.expect(instrument.unregisterCallback(testCallback));
    try std.testing.expectEqual(@as(usize, 1), instrument.callbacks.items.len);
    try std.testing.expect(instrument.callbacks.items[0] == dummyCallback);

    // Registering within remaining capacity should succeed without allocating
    try instrument.registerCallback(testCallback);
    try std.testing.expectEqual(@as(usize, 2), instrument.callbacks.items.len);

    // Unregister back to 1 callback
    try std.testing.expect(instrument.unregisterCallback(dummyCallback));
    try std.testing.expectEqual(@as(usize, 1), instrument.callbacks.items.len);
}

test "observable instrument unregisterCallback to empty with failing allocator" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    const io = std.testing.io;

    const instrument = try allocator.create(ObservableInstrument(.ObservableCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableCounter).init(allocator, io, null);
    defer instrument.deinit();

    try instrument.registerCallback(testCallback);
    try instrument.registerCallback(testCallbackWithAttrs);

    // Disallow any further allocations
    failing.fail_index = failing.alloc_index;

    // Unregister first callback
    try std.testing.expect(instrument.unregisterCallback(testCallback));
    // Unregister last callback without allocating
    try std.testing.expect(instrument.unregisterCallback(testCallbackWithAttrs));
    try std.testing.expectEqual(@as(usize, 0), instrument.callbacks.items.len);
}

test "exemplar/observable instruments capture a single callback instant" {
    inline for (.{ Kind.ObservableCounter, Kind.ObservableUpDownCounter, Kind.ObservableGauge }) |kind| {
        var instrument = ObservableInstrument(kind).init(std.testing.allocator, std.testing.io, null);
        defer instrument.deinit();
        instrument.exemplar_filter = .always_on;
        try instrument.registerCallback(exemplarCallback);
        var data = try instrument.measurementsData(std.testing.allocator);
        defer data.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), data.int.len);
        const first = data.int[0].exemplar_candidate.?;
        const second = data.int[1].exemplar_candidate.?;
        try std.testing.expectEqual(first.time_ns, second.time_ns);
        try std.testing.expectEqual(data.int[0].value, first.value.int);
        try std.testing.expectEqual(data.int[1].value, second.value.int);
    }
}

test "exemplar/observable duplicate callbacks and allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exemplarObservableAllocationFailure, .{});
}

fn exemplarObservableAllocationFailure(allocator: std.mem.Allocator) !void {
    var instrument = ObservableInstrument(.ObservableCounter).init(allocator, std.testing.io, null);
    defer instrument.deinit();
    instrument.exemplar_filter = .always_on;
    for (0..3) |_| try instrument.registerCallback(exemplarCallback);
    var data = try instrument.measurementsData(allocator);
    defer data.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), data.int.len);
    for (data.int) |point| try std.testing.expect(point.exemplar_candidate != null);
}

fn exemplarCallback(_: ObservedContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData {
    const points = try allocator.alloc(DataPoint(i64), 2);
    errdefer allocator.free(points);
    points[0] = try DataPoint(i64).new(allocator, 7, .{ "sensor", @as([]const u8, "one") });
    errdefer points[0].deinit(allocator);
    points[1] = try DataPoint(i64).new(allocator, 9, .{ "sensor", @as([]const u8, "two") });
    return .{ .int = points };
}

test "exemplar observable collection timestamps precede the next observation" {
    inline for (.{ Kind.ObservableCounter, Kind.ObservableUpDownCounter, Kind.ObservableGauge }) |kind| {
        var instrument = ObservableInstrument(kind).init(std.testing.allocator, std.testing.io, null);
        defer instrument.deinit();
        instrument.exemplar_filter = .always_on;
        try instrument.registerCallback(exemplarCallback);
        var first = try instrument.measurementsData(std.testing.allocator);
        defer first.deinit(std.testing.allocator);
        var second = try instrument.measurementsData(std.testing.allocator);
        defer second.deinit(std.testing.allocator);
        try std.testing.expect(first.int[0].timestamps != null);
        const end = first.int[0].timestamps.?.time_ns;
        for (first.int) |point| {
            try std.testing.expectEqual(end, point.timestamps.?.time_ns);
            try std.testing.expect(point.timestamps.?.start_time_ns != null);
            try std.testing.expect(point.timestamps.?.start_time_ns.? <= point.exemplar_candidate.?.time_ns);
            try std.testing.expect(point.exemplar_candidate.?.time_ns <= end);
        }
        for (second.int) |point| try std.testing.expect(end <= point.exemplar_candidate.?.time_ns);
    }
}
