const std = @import("std");

const spec = @import("spec.zig");
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const DataPoint = @import("measurement.zig").DataPoint;

const MeasurementsData = @import("measurement.zig").MeasurementsData;
const Measurements = @import("measurement.zig").Measurements;

const Instrument = @import("instrument.zig").Instrument;
const Kind = @import("instrument.zig").Kind;
const InstrumentOptions = @import("instrument.zig").InstrumentOptions;
const Counter = @import("instrument.zig").Counter;
const Histogram = @import("instrument.zig").Histogram;
const Gauge = @import("instrument.zig").Gauge;
const MetricReader = @import("../../sdk/metrics/reader.zig").MetricReader;

const defaultMeterVersion = "0.1.0";

/// MeterProvider is responsble for creating and managing meters.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#meterprovider
pub const MeterProvider = struct {
    allocator: std.mem.Allocator,
    meters: std.AutoHashMap(u64, Meter),
    readers: std.ArrayList(*MetricReader),

    const Self = @This();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const defaultMeterProvider = Self{
        .allocator = gpa.allocator(),
        .meters = std.AutoHashMap(u64, Meter).init(gpa.allocator()),
        .readers = std.ArrayList(*MetricReader).init(gpa.allocator()),
    };

    /// Create a new custom meter provider, using the specified allocator.
    pub fn init(alloc: std.mem.Allocator) !*Self {
        const provider = try alloc.create(Self);
        provider.* = Self{
            .allocator = alloc,
            .meters = std.AutoHashMap(u64, Meter).init(alloc),
            .readers = std.ArrayList(*MetricReader).init(alloc),
        };

        return provider;
    }

    /// Adopt the default MeterProvider.
    pub fn default() !*Self {
        const provider = try gpa.allocator().create(Self);
        provider.* = defaultMeterProvider;
        return provider;
    }

    /// Delete the meter provider and free up the memory allocated for it,
    /// as well as its owned Meters.
    pub fn shutdown(self: *Self) void {
        // TODO call shutdown on all readers.
        var meters = self.meters.valueIterator();
        while (meters.next()) |m| {
            m.deinit();
        }
        self.meters.deinit();
        self.readers.deinit();
        self.allocator.destroy(self);
    }

    /// Get a new meter by specifying its name.
    /// Options can be passed to specify a version, schemaURL, and attributes.
    /// SchemaURL and attributes are default to null.
    /// If a meter with the same name already exists, it will be returned.
    /// See https://opentelemetry.io/docs/specs/otel/metrics/api/#get-a-meter
    pub fn getMeter(self: *Self, options: MeterOptions) !*Meter {
        const i = Meter{
            .name = options.name,
            .version = options.version,
            .attributes = options.attributes,
            .schema_url = options.schema_url,
            .instruments = std.StringHashMap(*Instrument).init(self.allocator),
            .allocator = self.allocator,
        };
        // A Meter is identified uniquely by its name, version and schema_url.
        // We use a hash of these values to identify the meter.
        const meterId = spec.meterIdentifier(options);

        // Raise an error if a meter with the same name/version/schema_url is asked to be fetched with different attributes.
        if (self.meterExistsWithDifferentAttributes(meterId, options.attributes)) {
            return spec.ResourceError.MeterExistsWithDifferentAttributes;
        }
        const meter = try self.meters.getOrPutValue(meterId, i);

        return meter.value_ptr;
    }

    fn meterExistsWithDifferentAttributes(self: *Self, identifier: u64, attributes: ?[]Attribute) bool {
        if (self.meters.get(identifier)) |m| {
            return !std.mem.eql(u8, &std.mem.toBytes(m.attributes), &std.mem.toBytes(attributes));
        }
        return false;
    }

    pub fn addReader(self: *Self, m: *MetricReader) !void {
        if (m.meterProvider != null) {
            return spec.ResourceError.MetricReaderAlreadyAttached;
        }
        m.meterProvider = self;
        try self.readers.append(m);
    }
};

pub const MeterOptions = struct {
    name: []const u8,
    version: []const u8 = defaultMeterVersion,
    schema_url: ?[]const u8 = null,
    attributes: ?[]Attribute = null,
};

/// Meter is a named instance that is used to record measurements.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#meter
const Meter = struct {
    name: []const u8,
    version: []const u8,
    schema_url: ?[]const u8,
    attributes: ?[]Attribute = null,
    instruments: std.StringHashMap(*Instrument),
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
            std.debug.print(
                "Instrument with identifying name {s} already exists in meter {s}\n",
                .{ id, self.name },
            );
            return spec.ResourceError.InstrumentExistsWithSameNameAndIdentifyingFields;
        }
        return self.instruments.put(id, instrument);
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
        self.instruments.deinit();
        // Cleanup the meter attributes.
        if (self.attributes) |attrs| self.allocator.free(attrs);
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

test "meter can be created from custom provider" {
    const meter_name = "my-meter";
    const meter_version = "my-meter";
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = meter_name, .version = meter_version });

    std.debug.assert(std.mem.eql(u8, meter.name, meter_name));
    std.debug.assert(std.mem.eql(u8, meter.version, meter_version));
    std.debug.assert(meter.schema_url == null);
    std.debug.assert(meter.attributes == null);
}

test "meter can be created from default provider with schema url and attributes" {
    const meter_name = "my-meter";
    const meter_version = "my-meter";

    const mp = try MeterProvider.default();
    defer mp.shutdown();

    const val: []const u8 = "value";
    const attributes = try Attributes.from(mp.allocator, .{ "key", val });

    const meter = try mp.getMeter(.{ .name = meter_name, .version = meter_version, .schema_url = "http://foo.bar", .attributes = attributes });
    try std.testing.expectEqual(meter.name, meter_name);
    try std.testing.expectEqualStrings(meter.version, meter_version);
    try std.testing.expectEqualStrings(meter.schema_url.?, "http://foo.bar");
    std.debug.assert(std.mem.eql(u8, std.mem.asBytes(meter.attributes.?), std.mem.asBytes(attributes.?)));
}

test "meter has default version when creted with no options" {
    const mp = try MeterProvider.default();
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "ameter" });
    std.debug.assert(std.mem.eql(u8, meter.version, defaultMeterVersion));
}

test "getting same meter with different attributes returns an error" {
    const name = "my-meter";
    const version = "v1.2.3";
    const schema_url = "http://foo.bar";

    const mp = try MeterProvider.default();
    defer mp.shutdown();

    const val1: []const u8 = "value1";
    const val2: []const u8 = "value2";
    const attributes = try Attributes.from(mp.allocator, .{ "key1", val1 });

    _ = try mp.getMeter(.{ .name = name, .version = version, .schema_url = schema_url, .attributes = attributes });

    // modify the attributes adding one/
    // these attributes are not allocated with the same allocator as the meter.
    const attributesUpdated = try Attributes.from(std.testing.allocator, .{ "key1", val1, "key2", val2 });
    defer std.testing.allocator.free(attributesUpdated.?);

    const r = mp.getMeter(.{ .name = name, .version = version, .schema_url = schema_url, .attributes = attributesUpdated });
    try std.testing.expectError(spec.ResourceError.MeterExistsWithDifferentAttributes, r);
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
/// MetricReader's temporality and aggregation functions.
pub const AggregatedMetrics = struct {
    fn deduplicate(allocator: std.mem.Allocator, instr: *Instrument, aggregation: view.Aggregation) !MeasurementsData {
        // This function is only called on read/export
        // which is much less frequent than other SDK operations.
        @setCold(true);

        const allMeasurements: MeasurementsData = try instr.getInstrumentsData(allocator);
        defer allMeasurements.deinit(allocator);

        switch (allMeasurements) {
            .int => {
                var deduped = std.ArrayList(DataPoint(i64)).init(allocator);
                defer deduped.deinit();

                var temp = std.HashMap(Attributes, i64, Attributes.HashContext, std.hash_map.default_max_load_percentage).init(allocator);
                defer temp.deinit();

                for (allMeasurements.int) |measure| {
                    switch (aggregation) {
                        .Drop => return MeasurementsData{ .int = &[_]DataPoint(i64){} },
                        .Sum, .ExplicitBucketHistogram => {
                            const key = Attributes.with(measure.attributes);
                            const value = measure.value;
                            if (temp.get(key)) |v| {
                                const newValue = v + value;
                                try temp.put(key, newValue);
                            } else {
                                try temp.put(key, value);
                            }
                        },
                        .LastValue => {
                            const key = Attributes.with(measure.attributes);
                            try temp.put(key, measure.value);
                        },
                    }
                }

                var iter = temp.iterator();
                while (iter.next()) |entry| {
                    // TODO add sharedAttributes to the measurements attributes.
                    try deduped.append(DataPoint(i64){ .attributes = entry.key_ptr.*.attributes, .value = entry.value_ptr.* });
                }
                return .{ .int = try deduped.toOwnedSlice() };
            },
            .double => {
                var deduped = std.ArrayList(DataPoint(f64)).init(allocator);
                defer deduped.deinit();

                var temp = std.AutoHashMap(Attributes, f64).init(allocator);
                defer temp.deinit();

                for (allMeasurements.double) |measure| {
                    switch (aggregation) {
                        .Drop => return MeasurementsData{ .double = &[_]DataPoint(f64){} },
                        .Sum, .ExplicitBucketHistogram => {
                            const key = Attributes.with(measure.attributes);
                            const value = measure.value;
                            if (temp.get(key)) |v| {
                                const newValue = v + value;
                                try temp.put(key, newValue);
                            } else {
                                try temp.put(key, value);
                            }
                        },
                        .LastValue => {
                            const key = Attributes.with(measure.attributes);
                            try temp.put(key, measure.value);
                        },
                    }
                }

                var iter = temp.iterator();
                while (iter.next()) |entry| {
                    // TODO add sharedAttributes (the meter's attributes)to the measurements attributes.
                    try deduped.append(DataPoint(f64){ .attributes = entry.key_ptr.*.attributes, .value = entry.value_ptr.* });
                }
                return .{ .double = try deduped.toOwnedSlice() };
            },
        }
    }

    /// Fetch the aggreagted metrics from the meter.
    /// Each instrument is an entry of the slice.
    /// Caller owns the returned memory and it should be freed using the AggregatedMetrics allocator.
    pub fn fetch(allocator: std.mem.Allocator, meter: *Meter, aggregation: view.AggregationSelector) ![]Measurements {
        @setCold(true);

        meter.mx.lock();
        defer meter.mx.unlock();

        var result = try allocator.alloc(Measurements, meter.instruments.count());

        var iter = meter.instruments.valueIterator();
        var i: usize = 0;
        while (iter.next()) |instr| {
            result[i] = Measurements{
                .meterName = meter.name,
                .meterSchemaUrl = meter.schema_url,
                .meterAttributes = meter.attributes,
                .instrumentKind = instr.*.kind,
                .instrumentOptions = instr.*.opts,
                .data = try deduplicate(allocator, instr.*, aggregation(instr.*.kind)),
            };
            i += 1;
        }
        return result;
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

    const deduped = try AggregatedMetrics.deduplicate(std.testing.allocator, instr.*, .Sum);
    defer deduped.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(DataPoint(i64){ .value = 4 }, deduped.int[0]);
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

    var deduped = try AggregatedMetrics.deduplicate(std.testing.allocator, instr.*, .Sum);
    defer deduped.deinit(std.testing.allocator);

    const attrs = try Attributes.from(std.testing.allocator, .{ "key", val });
    defer if (attrs) |a| std.testing.allocator.free(a);

    try std.testing.expectEqualDeep(DataPoint(i64){
        .attributes = attrs,
        .value = 4,
    }, deduped.int[0]);
}

test "aggregated metrics fetch to owned slice" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{ .name = "test", .schema_url = "http://example.com" });
    var counter = try meter.createCounter(u64, .{ .name = "test-counter" });
    try counter.add(1, .{});
    try counter.add(3, .{});

    const result = try AggregatedMetrics.fetch(std.testing.allocator, meter, view.DefaultAggregationFor);
    defer {
        for (result) |m| {
            var data = m;
            data.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(1, result.len);
    try std.testing.expectEqualStrings(meter.name, result[0].meterName);
    try std.testing.expectEqualStrings(meter.schema_url.?, result[0].meterSchemaUrl.?);
    try std.testing.expectEqualStrings("test-counter", result[0].instrumentOptions.name);
    try std.testing.expectEqual(4, result[0].data.int[0].value);
}
