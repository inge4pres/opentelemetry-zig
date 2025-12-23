const std = @import("std");

const log = std.log.scoped(.meter);

const spec = @import("spec.zig");
const builtin = @import("builtin");
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

const DataPoint = @import("measurement.zig").DataPoint;
const HistogramDataPoint = @import("measurement.zig").HistogramDataPoint;
const aggregation = @import("../../sdk/metrics/aggregation.zig");
const ExponentialHistogramDataPoint = aggregation.ExponentialHistogramDataPoint;

const MeasurementsData = @import("measurement.zig").MeasurementsData;
const Measurements = @import("measurement.zig").Measurements;

const Instrument = @import("instrument.zig").Instrument;
const Kind = @import("instrument.zig").Kind;
const InstrumentOptions = @import("instrument.zig").InstrumentOptions;
const Counter = @import("instrument.zig").Counter;
const Histogram = @import("instrument.zig").Histogram;
const Gauge = @import("instrument.zig").Gauge;
const MetricReader = @import("../../sdk/metrics/reader.zig").MetricReader;

const AsyncInstrument = @import("async_instrument.zig");

// Import configuration module
const Configuration = @import("../../sdk/config.zig").Configuration;
const MetricsConfig = @import("../../sdk/config.zig").MetricsConfig;
const resource_attributes = @import("../../sdk/resource.zig");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

/// MeterProvider is responsble for creating and managing meters.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#meterprovider
pub const MeterProvider = struct {
    allocator: std.mem.Allocator,
    meters: std.HashMapUnmanaged(
        InstrumentationScope,
        Meter,
        InstrumentationScope.HashContext,
        std.hash_map.default_max_load_percentage,
    ),
    readers: std.ArrayListUnmanaged(*MetricReader),
    views: std.ArrayListUnmanaged(view.View),
    sdk_disabled: bool,
    // Configuration (accessed internally from global singleton)
    config: ?*const Configuration,
    // Resource attributes for this provider
    resource: ?[]const Attribute = null,

    mx: std.Thread.Mutex = std.Thread.Mutex{},

    const Self = @This();

    /// Create a new custom meter provider, using the specified allocator.
    pub fn init(alloc: std.mem.Allocator) !*Self {
        // Access global configuration (transparent to user)
        const cfg = Configuration.get();
        const sdk_disabled = if (cfg) |c| c.sdk_disabled else false;

        const provider = try alloc.create(Self);
        provider.* = Self{
            .allocator = alloc,
            .meters = .empty,
            .readers = .empty,
            .views = .empty,
            .sdk_disabled = sdk_disabled,
            .config = cfg,
            // Build resource attributes from config (empty if SDK disabled)
            .resource = if (sdk_disabled) null else if (cfg) |c| try resource_attributes.buildFromConfig(alloc, c) else null,
        };

        if (sdk_disabled) {
            std.log.info("MeterProvider: SDK disabled via OTEL_SDK_DISABLED", .{});
        }

        return provider;
    }

    /// Adopt the default MeterProvider.
    pub fn default() !*Self {
        switch (builtin.mode) {
            .Debug, .ReleaseSafe => return try Self.init(debug_allocator.allocator()),
            .ReleaseFast, .ReleaseSmall => return try Self.init(std.heap.smp_allocator),
        }
    }

    /// Delete the meter provider and free up the memory allocated for it,
    /// as well as its owned Meters.
    pub fn shutdown(self: *Self) void {
        self.mx.lock();

        var meters = self.meters.valueIterator();
        while (meters.next()) |m| {
            m.deinit();
        }
        self.meters.deinit(self.allocator);
        // TODO call shutdown on all readers?
        // This means users should not call shutdown on readers directly.
        self.readers.deinit(self.allocator);
        self.views.deinit(self.allocator);

        if (self.resource) |res| {
            resource_attributes.freeResource(self.allocator, res);
        }

        // Unlock before destroying the struct
        self.mx.unlock();
        self.allocator.destroy(self);
    }

    /// Get a new meter by specifying its name.
    /// Scope can be passed to specify a version, schemaURL, and attributes.
    /// SchemaURL and attributes are default to null.
    /// If a meter with the same name already exists, it will be returned.
    /// See https://opentelemetry.io/docs/specs/otel/metrics/api/#get-a-meter
    pub fn getMeter(self: *Self, scope: InstrumentationScope) !*Meter {
        self.mx.lock();
        defer self.mx.unlock();

        const i = Meter{
            .scope = scope,
            .instruments = .empty,
            .allocator = self.allocator,
        };

        const meter = try self.meters.getOrPutValue(self.allocator, scope, i);

        return meter.value_ptr;
    }

    pub fn addReader(self: *Self, m: *MetricReader) !void {
        self.mx.lock();
        defer self.mx.unlock();

        if (m.meterProvider != null) {
            return spec.ResourceError.MetricReaderAlreadyAttached;
        }
        m.meterProvider = self;
        try self.readers.append(self.allocator, m);
    }

    /// Register a view with this meter provider
    pub fn addView(self: *Self, new_view: view.View) !void {
        self.mx.lock();
        defer self.mx.unlock();

        try self.views.append(self.allocator, new_view);
    }

    /// Helper: Create a MetricReader configured with environment variable settings
    /// This convenience method uses OTEL_METRIC_* environment variables
    pub fn createReaderFromConfig(
        self: *Self,
        metric_exporter: *@import("../../sdk/metrics/exporter.zig").MetricExporter,
    ) !*MetricReader {
        const mc = self.config.metrics_config;
        const reader = try MetricReader.init(self.allocator, metric_exporter);

        // Apply export timeout from config
        reader.exportTimeout = mc.export_timeout_ms;

        return reader;
    }
};

/// Meter is a named instance that is used to record measurements.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#meter
const Meter = struct {
    scope: InstrumentationScope,
    instruments: std.StringHashMapUnmanaged(*Instrument),
    allocator: std.mem.Allocator,

    mx: std.Thread.Mutex = std.Thread.Mutex{},

    const Self = @This();

    /// Create a new Counter instrument using the specified type as the value type.
    /// This is a monotonic counter that can only be incremented.
    pub fn createCounter(self: *Self, comptime T: type, options: InstrumentOptions) !*Counter(T) {
        var i = try Instrument.new(.Counter, options, self.allocator);
        const c = try i.counter(T);
        errdefer self.allocator.destroy(c);
        try self.registerInstrument(i);

        return c;
    }

    /// Create a new UpDownCounter instrument using the specified type as the value type.
    /// This is a counter that can be incremented and decremented.
    pub fn createUpDownCounter(self: *Self, comptime T: type, options: InstrumentOptions) !*Counter(T) {
        var i = try Instrument.new(.UpDownCounter, options, self.allocator);
        const c = try i.upDownCounter(T);
        errdefer self.allocator.destroy(c);
        try self.registerInstrument(i);

        return c;
    }

    /// Create a new Histogram instrument using the specified type as the value type.
    /// A histogram is a metric that samples observations and counts them in different buckets.
    pub fn createHistogram(self: *Self, comptime T: type, options: InstrumentOptions) !*Histogram(T) {
        var i = try Instrument.new(.Histogram, options, self.allocator);
        const h = try i.histogram(T);
        errdefer self.allocator.destroy(h);
        try self.registerInstrument(i);

        return h;
    }

    /// Create a new Gauge instrument using the specified type as the value type.
    /// A gauge is a metric that represents a single numerical value that can arbitrarily go up and down,
    /// and represents a point-in-time value.
    pub fn createGauge(self: *Self, comptime T: type, options: InstrumentOptions) !*Gauge(T) {
        var i = try Instrument.new(.Gauge, options, self.allocator);
        const g = try i.gauge(T);
        errdefer self.allocator.destroy(g);
        try self.registerInstrument(i);

        return g;
    }

    /// Create an ObservableCounter instrument that can be used to observe values asynchronously.
    /// This instrument is used to report counters with absolute values.
    /// See https://opentelemetry.io/docs/specs/otel/metrics/api/#asynchronous-counter.
    pub fn createObservableCounter(
        self: *Self,
        options: InstrumentOptions,
        context: AsyncInstrument.ObservedContext,
        callbacks: ?[]AsyncInstrument.ObserveMeasures,
    ) !*AsyncInstrument.ObservableInstrument(.ObservableCounter) {
        var i = try Instrument.new(.ObservableCounter, options, self.allocator);
        const c = try i.asyncCounter(context, callbacks);
        errdefer self.allocator.destroy(c);
        try self.registerInstrument(i);

        return c;
    }

    /// Create an ObservableUpDownCounter instrument that can be used to observe values asynchronously.
    /// This instrument is used to report counters with absolute values that can go up and down.
    /// See https://opentelemetry.io/docs/specs/otel/metrics/api/#asynchronous-updowncounter.
    pub fn createObservableUpDownCounter(
        self: *Self,
        options: InstrumentOptions,
        context: AsyncInstrument.ObservedContext,
        callbacks: ?[]AsyncInstrument.ObserveMeasures,
    ) !*AsyncInstrument.ObservableInstrument(.ObservableUpDownCounter) {
        var i = try Instrument.new(.ObservableUpDownCounter, options, self.allocator);
        const c = try i.asyncUpDownCounter(context, callbacks);
        errdefer self.allocator.destroy(c);
        try self.registerInstrument(i);

        return c;
    }

    /// Create an ObservableGauge instrument that can be used to observe values asynchronously.
    /// See https://opentelemetry.io/docs/specs/otel/metrics/api/#asynchronous-gauge.
    pub fn createObservableGauge(
        self: *Self,
        options: InstrumentOptions,
        context: AsyncInstrument.ObservedContext,
        callbacks: ?[]AsyncInstrument.ObserveMeasures,
    ) !*AsyncInstrument.ObservableInstrument(.ObservableGauge) {
        var i = try Instrument.new(.ObservableGauge, options, self.allocator);
        const g = try i.asyncGauge(context, callbacks);
        errdefer self.allocator.destroy(g);
        try self.registerInstrument(i);

        return g;
    }

    // Check that the instrument is not already registered with the same name identifier.
    // Name is case-insensitive.
    // The remaining are also forming the identifier.
    fn registerInstrument(self: *Self, instrument: *Instrument) !void {
        self.mx.lock();
        defer self.mx.unlock();

        const id = try spec.instrumentIdentifier(
            self.allocator,
            instrument.opts.name,
            instrument.kind.toString(),
            instrument.opts.unit orelse "",
            instrument.opts.description orelse "",
        );

        if (self.instruments.contains(id)) {
            log.warn(
                "Instrument with identifying name {s} already exists in meter {s}",
                .{ id, self.scope.name },
            );
            return spec.ResourceError.InstrumentExistsWithSameNameAndIdentifyingFields;
        }
        return self.instruments.put(self.allocator, id, instrument);
    }

    fn deinit(self: *Self) void {
        var instrs = self.instruments.iterator();
        while (instrs.next()) |i| {
            // Instrument.deinit() will free up the memory allocated for the instrument,
            i.value_ptr.*.deinit();
            // Also free up the memory allocated for the instrument keys.
            self.allocator.free(i.key_ptr.*);
        }
        // Cleanup Meters' Instruments values.
        self.instruments.deinit(self.allocator);
        // Cleanup the meter attributes.
        if (self.scope.attributes) |attrs| self.allocator.free(attrs);
    }
};

test "default meter provider can be fetched" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();

    std.debug.assert(@intFromPtr(&mp) != 0);
}

test "custom meter provider can be created" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    std.debug.assert(@intFromPtr(&mp) != 0);
}

test "meter provider with config from environment" {
    const cfg = try Configuration.initFromEnv(std.testing.allocator);
    defer cfg.deinit();
    Configuration.set(cfg);

    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    // Verify config was loaded with defaults
    try std.testing.expectEqual(@as(u64, 60000), mp.config.?.metrics_config.export_interval_ms);
    try std.testing.expectEqual(@as(u64, 30000), mp.config.?.metrics_config.export_timeout_ms);
    try std.testing.expectEqual(MetricsConfig.ExporterType.otlp, mp.config.?.metrics_config.exporter);
    try std.testing.expectEqual(MetricsConfig.ExemplarFilter.trace_based, mp.config.?.metrics_config.exemplar_filter);
}

test "meter can be created from custom provider" {
    const meter_name = "my-meter";
    const meter_version = "my-meter";
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = meter_name, .version = meter_version });

    std.debug.assert(std.mem.eql(u8, meter.scope.name, meter_name));
    std.debug.assert(std.mem.eql(u8, meter.scope.version.?, meter_version));
    std.debug.assert(meter.scope.schema_url == null);
    std.debug.assert(meter.scope.attributes == null);
}

test "meter can be created from default provider with schema url and attributes" {
    const meter_name = "my-meter";
    const meter_version = "my-meter";

    const mp = try MeterProvider.default();
    defer mp.shutdown();

    const val: []const u8 = "value";
    const attributes = try Attributes.from(mp.allocator, .{ "key", val });

    const meter = try mp.getMeter(.{ .name = meter_name, .version = meter_version, .schema_url = "http://foo.bar", .attributes = attributes });
    try std.testing.expectEqual(meter.scope.name, meter_name);
    try std.testing.expectEqualStrings(meter.scope.version.?, meter_version);
    try std.testing.expectEqualStrings(meter.scope.schema_url.?, "http://foo.bar");
    std.debug.assert(std.mem.eql(u8, std.mem.sliceAsBytes(meter.scope.attributes.?), std.mem.sliceAsBytes(attributes.?)));
}

test "meter register instrument twice with same name fails" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "my-meter" });

    const counterName = "beautiful-counter";
    _ = try meter.createCounter(u16, .{ .name = counterName });
    const r = meter.createCounter(u16, .{ .name = counterName });

    try std.testing.expectError(spec.ResourceError.InstrumentExistsWithSameNameAndIdentifyingFields, r);
}

test "meter register instrument" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "my-meter" });

    const counter = try meter.createCounter(u16, .{ .name = "my-counter" });
    _ = try meter.createHistogram(u16, .{ .name = "my-histogram" });

    try std.testing.expectEqual(2, meter.instruments.count());

    const id: []const u8 = try spec.instrumentIdentifier(
        std.testing.allocator,
        "my-counter",
        Kind.Counter.toString(),
        "",
        "",
    );
    defer std.testing.allocator.free(id);

    if (meter.instruments.get(id)) |inst| {
        try std.testing.expectEqual(counter, inst.data.Counter_u16);
    } else {
        unreachable;
    }
}

test "meter provider adds metric reader" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    var mr = MetricReader{ .allocator = std.testing.allocator };
    try mp.addReader(&mr);

    std.debug.assert(mp.readers.items.len == 1);
}

test "meter provider adds multiple metric readers" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    var mr1 = MetricReader{ .allocator = std.testing.allocator };
    var mr2 = MetricReader{ .allocator = std.testing.allocator };
    try mp.addReader(&mr1);
    try mp.addReader(&mr2);

    std.debug.assert(mp.readers.items.len == 2);
}

test "metric reader cannot be registered with multiple providers" {
    const mp1 = try MeterProvider.init(std.testing.allocator);
    defer mp1.shutdown();

    const mp2 = try MeterProvider.init(std.testing.allocator);
    defer mp2.shutdown();

    var mr = MetricReader{ .allocator = std.testing.allocator };

    try mp1.addReader(&mr);
    const err = mp2.addReader(&mr);
    try std.testing.expectError(spec.ResourceError.MetricReaderAlreadyAttached, err);
}

test "metric reader cannot be registered twice on same meter provider" {
    const mp1 = try MeterProvider.init(std.testing.allocator);
    defer mp1.shutdown();

    var mr = MetricReader{ .allocator = std.testing.allocator };

    try mp1.addReader(&mr);
    const err = mp1.addReader(&mr);
    try std.testing.expectError(spec.ResourceError.MetricReaderAlreadyAttached, err);
}

test "meter provider end to end" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "service.company.com" });

    var counter = try meter.createCounter(u32, .{
        .name = "loc",
        .description = "lines of code written",
    });
    const meVal: []const u8 = "person@company.com";

    try counter.add(1000000, .{ "author", meVal });
    try counter.add(10, .{ "author", meVal });

    var hist = try meter.createHistogram(u16, .{ .name = "my-histogram" });
    const v: []const u8 = "success";

    try hist.record(1234, .{});
    try hist.record(4567, .{ "amazing", v });

    std.debug.assert(meter.instruments.count() == 2);
}

test "meter provider with arena allocator" {
    var buffer: [10 << 20]u8 = undefined;
    var fb = std.heap.FixedBufferAllocator.init(&buffer);
    defer fb.reset();
    var arena = std.heap.ArenaAllocator.init(fb.allocator());
    defer arena.deinit();

    const mp = try MeterProvider.init(arena.allocator());
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "service.company.com" });

    var counter = try meter.createCounter(u32, .{
        .name = "loc",
        .description = "lines of code written",
    });
    const meVal: []const u8 = "test";

    try counter.add(1, .{ "author", meVal });
}

const view = @import("../../sdk/metrics/view.zig");

/// AggregatedMetrics is a collection of metrics that have been aggregated using the
/// MeterProvider's view configured by users or falling back to the
/// MetricReader's temporality and aggregation functions.
pub const AggregatedMetrics = struct {
    fn sum(comptime T: type, data_points: []DataPoint(T), current_time: u64, allocator: std.mem.Allocator) ![]DataPoint(T) {
        var deduped = std.ArrayHashMap(
            Attributes,
            DataPoint(T),
            Attributes.ArrayHashContext,
            true,
        ).init(allocator);
        // No need to cleanup the keys, they are reference to the same Attribute slices from data_points.
        defer deduped.deinit();

        for (data_points) |dp| {
            const key = Attributes.with(dp.attributes);
            const gop = try deduped.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = try dp.deepCopy(allocator) else gop.value_ptr.*.value += dp.value;
            // Add timestamps that will be used in temporal aggregation.
            gop.value_ptr.*.timestamps = .{ .start_time_ns = current_time, .time_ns = current_time };
        }
        return allocator.dupe(DataPoint(T), deduped.values());
    }

    fn lastValue(comptime T: type, data_points: []DataPoint(T), current_time: u64, allocator: std.mem.Allocator) ![]DataPoint(T) {
        var deduped = std.ArrayHashMap(
            Attributes,
            DataPoint(T),
            Attributes.ArrayHashContext,
            true,
        ).init(allocator);
        defer deduped.deinit();

        for (data_points) |dp| {
            var duped = try dp.deepCopy(allocator);
            // Add timestamps that will be used in temporal aggregation.
            duped.timestamps = .{ .start_time_ns = current_time, .time_ns = current_time };

            try deduped.put(Attributes.with(dp.attributes), duped);
        }
        return allocator.dupe(DataPoint(T), deduped.values());
    }

    fn aggregate(allocator: std.mem.Allocator, data_points: MeasurementsData, aggregation_type: view.Aggregation) !?MeasurementsData {
        // If there are no data points, we can return early.
        if (data_points.isEmpty()) return null;

        // After aggreating, the original data needs to go away.
        // The returned aggregated data copy the values and attributes from the originals.
        defer {
            switch (data_points) {
                inline else => |list| {
                    for (list) |*dp| {
                        dp.deinit(allocator);
                    }
                    allocator.free(list);
                },
            }
        }

        const current_time: u64 = @intCast(std.time.nanoTimestamp());

        // Processing pipeline is split by aggregation type
        const aggregated: ?MeasurementsData = switch (aggregation_type.getType()) {
            .Drop => null,
            .Sum => switch (data_points) {
                .int => MeasurementsData{ .int = try sum(i64, data_points.int, current_time, allocator) },
                .double => MeasurementsData{ .double = try sum(f64, data_points.double, current_time, allocator) },
                // Sum aggregation is not supported for histograms data points.
                // FIXME we should probably return an error here.
                // Specification does not seem to be clear...
                .histogram, .exponential_histogram => null,
            },
            .LastValue => switch (data_points) {
                .int => MeasurementsData{ .int = try lastValue(i64, data_points.int, current_time, allocator) },
                .double => MeasurementsData{ .double = try lastValue(f64, data_points.double, current_time, allocator) },
                // LastValue aggregation is not supported for histograms data points.
                // FIXME we should probably return an error here.
                // Specification does not seem to be clear...
                .histogram, .exponential_histogram => null,
            },
            .ExplicitBucketHistogram => switch (data_points) {
                .exponential_histogram => null,
                .int => blk: {
                    const config = aggregation_type.ExplicitBucketHistogram;
                    const buckets = config.buckets;
                    const aggregated = try aggregation.aggregateExplicitBucketHistogram(i64, allocator, data_points.int, buckets, config.record_min_max);
                    break :blk MeasurementsData{ .histogram = aggregated };
                },
                .double => blk: {
                    const config = aggregation_type.ExplicitBucketHistogram;
                    const buckets = config.buckets;
                    const aggregated = try aggregation.aggregateExplicitBucketHistogram(f64, allocator, data_points.double, buckets, config.record_min_max);
                    break :blk MeasurementsData{ .histogram = aggregated };
                },
                .histogram => blk: {
                    // Legacy support - if somehow we still get pre-aggregated histogram data, just pass it through
                    const ret = try allocator.alloc(DataPoint(HistogramDataPoint), data_points.histogram.len);
                    for (data_points.histogram, 0..) |dp, i| {
                        var d = try dp.deepCopy(allocator);
                        d.timestamps = .{ .time_ns = current_time };
                        ret[i] = d;
                    }
                    break :blk MeasurementsData{ .histogram = ret };
                },
            },
            .ExponentialBucketHistogram => switch (data_points) {
                .histogram => null,
                .int => blk: {
                    const config = aggregation_type.ExponentialBucketHistogram;
                    const aggregated = try aggregation.aggregateExponentialBucketHistogram(i64, allocator, data_points.int, config.max_scale, config.max_size, config.record_min_max);
                    break :blk MeasurementsData{ .exponential_histogram = aggregated };
                },
                .double => blk: {
                    const config = aggregation_type.ExponentialBucketHistogram;
                    const aggregated = try aggregation.aggregateExponentialBucketHistogram(f64, allocator, data_points.double, config.max_scale, config.max_size, config.record_min_max);
                    break :blk MeasurementsData{ .exponential_histogram = aggregated };
                },
                .exponential_histogram => blk: {
                    // Legacy support - if somehow we still get pre-aggregated exponential histogram data, just pass it through
                    const ret = try allocator.alloc(DataPoint(ExponentialHistogramDataPoint), data_points.exponential_histogram.len);
                    for (data_points.exponential_histogram, 0..) |dp, i| {
                        var d = try dp.deepCopy(allocator);
                        d.timestamps = .{ .time_ns = current_time };
                        ret[i] = d;
                    }
                    break :blk MeasurementsData{ .exponential_histogram = ret };
                },
            },
        };
        return aggregated orelse null;
    }

    /// Fetch the aggreagted metrics from the meter.
    /// Each instrument is an entry of the slice.
    /// Caller owns the returned memory and it should be freed using the AggregatedMetrics allocator.
    /// If aggregation_override is provided, it takes precedence over the view system.
    pub fn fetch(allocator: std.mem.Allocator, meter: *Meter, views: []const view.View, aggregation_override: ?view.AggregationSelector) ![]Measurements {
        meter.mx.lock();
        defer meter.mx.unlock();

        var results = std.ArrayList(Measurements){};

        var iter = meter.instruments.valueIterator();
        while (iter.next()) |instr| {
            // Get the data points from the instrument and reset their state,
            const data_points: MeasurementsData = try instr.*.getInstrumentsData(allocator);

            // Determine aggregation: override takes precedence over view system
            const aggregation_type = if (aggregation_override) |override_fn|
                override_fn(instr.*.kind)
            else
                view.aggregationForViews(views, instr.*, &meter.scope);

            const aggregated_data = try aggregate(allocator, data_points, aggregation_type);
            // then fill the result with the aggregated data points
            // only if there are data points.
            if (aggregated_data) |agg| {
                try results.append(allocator, Measurements{
                    .scope = .{
                        .name = meter.scope.name,
                        .version = meter.scope.version,
                        .schema_url = meter.scope.schema_url,
                        .attributes = meter.scope.attributes,
                    },
                    .instrumentKind = instr.*.kind,
                    .instrumentOptions = instr.*.opts,
                    .data = agg,
                });
            }
        }
        return try results.toOwnedSlice(allocator);
    }
};

test "aggregated metrics deduplicated from meter without attributes" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{ .name = "test", .schema_url = "http://example.com" });
    var counter = try meter.createCounter(u64, .{ .name = "test-counter" });
    try counter.add(1, .{});
    try counter.add(3, .{});

    var iter = meter.instruments.valueIterator();
    const instr = iter.next() orelse unreachable;

    const data_points = try instr.*.getInstrumentsData(std.testing.allocator);

    const deduped = try AggregatedMetrics.aggregate(std.testing.allocator, data_points, .Sum);
    defer switch (deduped.?) {
        inline else => |m| std.testing.allocator.free(m),
    };

    try std.testing.expectEqualDeep(DataPoint(i64){
        .value = 4,
        .timestamps = deduped.?.int[0].timestamps orelse @panic("missing timestamps"),
    }, deduped.?.int[0]);
}

test "aggregated metrics deduplicated from meter with attributes" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meterVal: []const u8 = "meter_val";
    const meter = try mp.getMeter(.{
        .name = "test",
        .schema_url = "http://example.com",
        .attributes = try Attributes.from(std.testing.allocator, .{ "meter_attr", meterVal }),
    });
    var counter = try meter.createCounter(u64, .{ .name = "test-counter" });
    const val: []const u8 = "test";
    try counter.add(1, .{ "key", val });
    try counter.add(3, .{ "key", val });

    var iter = meter.instruments.valueIterator();
    const instr = iter.next() orelse unreachable;

    const data_points = try instr.*.getInstrumentsData(std.testing.allocator);

    const deduped = try AggregatedMetrics.aggregate(std.testing.allocator, data_points, .Sum);
    defer switch (deduped.?) {
        inline else => |m| {
            for (deduped.?.int) |*dp| {
                dp.deinit(std.testing.allocator);
            }
            std.testing.allocator.free(m);
        },
    };

    const attrs = try Attributes.from(std.testing.allocator, .{ "key", val });
    defer if (attrs) |a| std.testing.allocator.free(a);

    try std.testing.expectEqualDeep(DataPoint(i64){
        .attributes = attrs,
        .value = 4,
        .timestamps = deduped.?.int[0].timestamps orelse @panic("missing timestamps"),
    }, deduped.?.int[0]);
}

test "aggregated metrics fetch to owned slice" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "test", .schema_url = "http://example.com" });
    var counter = try meter.createCounter(u64, .{ .name = "test-counter" });
    try counter.add(1, .{});
    try counter.add(3, .{});

    const result = try AggregatedMetrics.fetch(std.testing.allocator, meter, mp.views.items, null);
    defer {
        for (result) |m| {
            var data = m;
            data.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings(meter.scope.name, result[0].scope.name);
    try std.testing.expectEqualStrings(meter.scope.schema_url.?, result[0].scope.schema_url.?);
    try std.testing.expectEqualStrings("test-counter", result[0].instrumentOptions.name);
    try std.testing.expectEqual(4, result[0].data.int[0].value);
}

test "aggregated metrics do not duplicate data points" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "test", .schema_url = "http://example.com" });
    var counter = try meter.createCounter(u64, .{ .name = "test-counter" });
    try counter.add(1, .{});
    try counter.add(3, .{});

    const result = try AggregatedMetrics.fetch(std.testing.allocator, meter, mp.views.items, null);
    defer {
        for (result) |m| {
            var data = m;
            data.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqual(1, result[0].data.int.len);

    const result_second = try AggregatedMetrics.fetch(std.testing.allocator, meter, mp.views.items, null);
    defer std.testing.allocator.free(result_second);

    std.testing.expectEqual(0, result_second.len) catch |err| {
        log.err("bad result from AggregatedMetrics.fetch():\n{}", .{result_second[0]});
        return err;
    };
}

test "aggregated metrics have timestamps" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "test", .schema_url = "http://example.com" });
    var counter = try meter.createCounter(u64, .{ .name = "test-counter" });
    try counter.add(1, .{});
    try counter.add(3, .{});

    const result = try AggregatedMetrics.fetch(std.testing.allocator, meter, mp.views.items, null);
    defer {
        for (result) |m| {
            var data = m;
            data.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqual(4, result[0].data.int[0].value);
    try std.testing.expect(result[0].data.int[0].timestamps.?.start_time_ns.? > 0);
    try std.testing.expect(result[0].data.int[0].timestamps.?.time_ns > 0);
}

test "aggregated metrics with custom views" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "test", .schema_url = "http://example.com" });
    var counter = try meter.createCounter(u64, .{ .name = "test_counter" });
    try counter.add(1, .{});

    // Test with empty views slice (should use default aggregation)
    const empty_views: []const view.View = &[_]view.View{};
    const result_no_views = try AggregatedMetrics.fetch(std.testing.allocator, meter, empty_views, null);
    defer {
        for (result_no_views) |m| {
            var data = m;
            data.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(result_no_views);
    }
    try std.testing.expectEqual(1, result_no_views.len);
    try std.testing.expectEqual(1, result_no_views[0].data.int[0].value);

    // Create a view that drops this specific metric
    try mp.addView(view.View{
        .instrument_selector = view.InstrumentSelector{
            .name = "test_counter",
        },
        .aggregation = .Drop,
        .temporality = .Cumulative,
    });

    // Test with views from MeterProvider (should drop metric)
    const result_with_views = try AggregatedMetrics.fetch(std.testing.allocator, meter, mp.views.items, null);
    defer std.testing.allocator.free(result_with_views);
    try std.testing.expectEqual(0, result_with_views.len);
}

test "view associated with meter provider" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    // Create a view that matches histograms and uses explicit bucket aggregation
    const histogram_view = view.View{
        .instrument_selector = .{ .kind = .Histogram },
        .aggregation = .{ .ExplicitBucketHistogram = .{ .buckets = &.{ 0.1, 1.0, 10.0 } } },
        .temporality = .Cumulative,
    };

    try mp.addView(histogram_view);

    const meter = try mp.getMeter(.{ .name = "test" });

    // Create real instruments through the meter (proper way)
    var histogram = try meter.createHistogram(f64, .{ .name = "test-histogram" });
    var counter = try meter.createCounter(u64, .{ .name = "test-counter" });

    // Get the underlying instruments from the meter's registry
    var hist_instr: ?*Instrument = null;
    var counter_instr: ?*Instrument = null;

    // Find the instruments in the meter's registry
    var iter = meter.instruments.iterator();
    while (iter.next()) |entry| {
        const instr = entry.value_ptr.*;
        if (std.mem.eql(u8, instr.opts.name, "test-histogram")) {
            hist_instr = instr;
        } else if (std.mem.eql(u8, instr.opts.name, "test-counter")) {
            counter_instr = instr;
        }
    }

    try std.testing.expect(hist_instr != null);
    try std.testing.expect(counter_instr != null);

    // The histogram should get the custom aggregation from the view
    const hist_aggregation = view.aggregationForViews(mp.views.items, hist_instr.?, &meter.scope);
    try std.testing.expectEqual(view.AggregationType.ExplicitBucketHistogram, hist_aggregation.getType());
    try std.testing.expectEqual(@as(usize, 3), hist_aggregation.ExplicitBucketHistogram.buckets.len);

    // The counter should get the default aggregation (no view matches)
    const counter_aggregation = view.aggregationForViews(mp.views.items, counter_instr.?, &meter.scope);
    try std.testing.expectEqual(view.AggregationType.Sum, counter_aggregation.getType());

    // Test temporality as well
    const hist_temporality = view.temporalityForViews(mp.views.items, hist_instr.?, &meter.scope);
    try std.testing.expectEqual(view.Temporality.Cumulative, hist_temporality);

    const counter_temporality = view.temporalityForViews(mp.views.items, counter_instr.?, &meter.scope);
    try std.testing.expectEqual(view.Temporality.Cumulative, counter_temporality); // Default for counters

    // Verify the instruments work
    try histogram.record(5.0, .{});
    try counter.add(1, .{});
}

test "view is additive processing with conflicts" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "test", .schema_url = "http://example.com" });
    var histogram = try meter.createHistogram(f64, .{ .name = "test_histogram" });
    try histogram.record(1.0, .{});

    // Add first view with specific aggregation
    try mp.addView(view.View{
        .instrument_selector = view.InstrumentSelector{
            .name = "test_histogram",
        },
        .aggregation = .{ .ExplicitBucketHistogram = .{
            .buckets = &[_]f64{ 1.0, 2.0, 5.0 },
        } },
        .temporality = .Cumulative,
        .name = "renamed_histogram",
    });

    // Add second view with conflicting aggregation (should log warning)
    try mp.addView(view.View{
        .instrument_selector = view.InstrumentSelector{
            .name = "test_histogram",
        },
        .aggregation = .{
            .ExplicitBucketHistogram = .{
                .buckets = &[_]f64{ 0.5, 1.0, 2.0, 5.0, 10.0 }, // Different buckets - should cause conflict
            },
        },
        .temporality = .Delta, // Different temporality - should cause conflict
        .name = "another_name", // Different name - should cause conflict
    });

    // Test that the last view's configuration is used (additive behavior)
    const result = try AggregatedMetrics.fetch(std.testing.allocator, meter, mp.views.items, null);
    defer {
        for (result) |m| {
            var data = m;
            data.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(result);
    }

    // Should still have 1 histogram (not dropped)
    try std.testing.expectEqual(1, result.len);
    // Data should be present
    try std.testing.expect(result[0].data.histogram.len > 0);
}
