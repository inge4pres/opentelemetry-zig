const std = @import("std");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("../opentelemetry/proto/common/v1.pb.zig");
const pbutils = @import("../pbutils.zig");
const spec = @import("spec.zig");

const InstrumentOptions = @import("instrument.zig").InstrumentOptions;
const Counter = @import("instrument.zig").Counter;
const Histogram = @import("instrument.zig").Histogram;
const Gauge = @import("instrument.zig").Gauge;

const defaultMeterVersion = "0.1.0";

/// MeterProvider is responsble for creating and managing meters.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#meterprovider
pub const MeterProvider = struct {
    allocator: std.mem.Allocator,
    meters: std.AutoHashMap(u64, Meter),

    const Self = @This();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    /// Create a new custom meter provider, using the specified allocator.
    pub fn init(alloc: std.mem.Allocator) !*Self {
        const provider = try alloc.create(Self);
        provider.* = Self{
            .allocator = alloc,
            .meters = std.AutoHashMap(u64, Meter).init(alloc),
        };

        return provider;
    }

    /// Default MeterProvider
    pub fn default() !*Self {
        return try init(gpa.allocator());
    }

    /// Delete the meter provider and free up the memory allocated for it.
    pub fn deinit(self: *Self) void {
        self.meters.deinit();
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
            .instruments = std.StringHashMap(InstrumentOptions).init(self.allocator),
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

    fn meterExistsWithDifferentAttributes(self: *Self, identifier: u64, attributes: ?pbcommon.KeyValueList) bool {
        if (self.meters.get(identifier)) |m| {
            if (!std.mem.eql(u8, &std.mem.toBytes(m.attributes), &std.mem.toBytes(attributes))) {
                return true;
            }
        }
        return false;
    }
};

pub const MeterOptions = struct {
    name: []const u8,
    version: []const u8 = defaultMeterVersion,
    schema_url: ?[]const u8 = null,
    attributes: ?pbcommon.KeyValueList = null,
};

/// Meter is a named instance that is used to record measurements.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#meter
const Meter = struct {
    name: []const u8,
    version: []const u8,
    schema_url: ?[]const u8,
    attributes: ?pbcommon.KeyValueList,
    // Maybe the value of this map should be a new type, holding the instrument and its kind as well.
    instruments: std.StringHashMap(InstrumentOptions),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new Counter instrument using the specified type as the value type.
    /// Options to identify the counter must be provided: a mandatory name,
    /// and optional description and unit.
    pub fn createCounter(self: *Self, comptime T: type, options: InstrumentOptions) !Counter(T) {
        switch (T) {
            usize, u8, u16, u32, u64, f32, f64 => {},
            else => {
                std.debug.print("Unsupported monotonic counter value type: {s}\n", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        }

        const counter = try Counter(T).init(options, self.allocator);
        // var i = Instrument(T){ .inner = counter };
        try self.registerInstrument(options);

        return counter;
    }

    pub fn createHistogram(self: *Self, comptime T: type, options: InstrumentOptions) !Histogram(T) {
        switch (T) {
            usize, u8, u16, u32, u64, f32, f64 => {},
            else => {
                std.debug.print("Unsupported histogram value type: {s}\n", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        }

        const histogram = try Histogram(T).init(options, self.allocator);
        // var i = Instrument(T){ .inner = histogram };
        try self.registerInstrument(options);

        return histogram;
    }

    pub fn createGauge(self: *Self, comptime T: type, options: InstrumentOptions) !Gauge(T) {
        const gauge = try Gauge(T).init(options, self.allocator);
        // var i = Instrument(T){ .inner = gauge };
        try self.registerInstrument(options);

        return gauge;
    }

    // Check that the instrument is not already registered with the same name.
    // Name is case-insensitive.
    // FIXME this is not actually storing the instrument, but the options.
    // how are we supposed to read from them?
    fn registerInstrument(self: *Self, opts: InstrumentOptions) !void {
        if (self.instruments.getEntry(spec.lowerCaseName(opts.name))) |_| {
            return spec.ResourceError.InstrumentExistsWithSameName;
        }
        try self.instruments.put(spec.lowerCaseName(opts.name), opts);
    }
};

test "default meter provider can be fetched" {
    const mp = try MeterProvider.default();
    defer mp.deinit();

    std.debug.assert(@intFromPtr(&mp) != 0);
}

test "custom meter provider can be created" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.deinit();

    std.debug.assert(@intFromPtr(&mp) != 0);
}

test "meter can be created from custom provider" {
    const meter_name = "my-meter";
    const meter_version = "my-meter";
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.deinit();

    const meter = try mp.getMeter(.{ .name = meter_name, .version = meter_version });

    std.debug.assert(std.mem.eql(u8, meter.name, meter_name));
    std.debug.assert(std.mem.eql(u8, meter.version, meter_version));
    std.debug.assert(meter.schema_url == null);
    std.debug.assert(meter.attributes == null);
}

test "meter can be created from default provider with schema url and attributes" {
    const meter_name = "my-meter";
    const meter_version = "my-meter";
    const attributes = pbcommon.KeyValueList{ .values = std.ArrayList(pbcommon.KeyValue).init(std.testing.allocator) };
    const mp = try MeterProvider.default();
    defer mp.deinit();

    const meter = try mp.getMeter(.{ .name = meter_name, .version = meter_version, .schema_url = "http://foo.bar", .attributes = attributes });
    std.debug.assert(std.mem.eql(u8, meter.name, meter_name));
    std.debug.assert(std.mem.eql(u8, meter.version, meter_version));
    std.debug.assert(std.mem.eql(u8, meter.schema_url.?, "http://foo.bar"));
    std.debug.assert(meter.attributes.?.values.items.len == attributes.values.items.len);
}

test "meter has default version when creted with no options" {
    const mp = try MeterProvider.default();
    defer mp.deinit();

    const meter = try mp.getMeter(.{ .name = "ameter" });
    std.debug.assert(std.mem.eql(u8, meter.version, defaultMeterVersion));
}

test "getting same meter with different attributes returns an error" {
    const name = "my-meter";
    const version = "v1.2.3";
    const schema_url = "http://foo.bar";
    var attributes = pbcommon.KeyValueList{ .values = std.ArrayList(pbcommon.KeyValue).init(std.testing.allocator) };
    defer attributes.values.deinit();
    try attributes.values.append(pbcommon.KeyValue{ .key = .{ .Const = "key" }, .value = pbcommon.AnyValue{ .value = .{ .string_value = .{ .Const = "value" } } } });

    const mp = try MeterProvider.default();
    _ = try mp.getMeter(.{ .name = name, .version = version, .schema_url = schema_url, .attributes = attributes });
    // modify the attributes adding one
    try attributes.values.append(pbcommon.KeyValue{ .key = .{ .Const = "key2" }, .value = pbcommon.AnyValue{ .value = .{ .string_value = .{ .Const = "value2" } } } });

    const r = mp.getMeter(.{ .name = name, .version = version, .schema_url = schema_url, .attributes = attributes });
    try std.testing.expectError(spec.ResourceError.MeterExistsWithDifferentAttributes, r);
}
