const std = @import("std");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pb_common = @import("opentelemetry/proto/common/v1.pb.zig");
const pb_metrics = @import("opentelemetry/proto/metrics/v1.pb.zig");
const pbutils = @import("pb_utils.zig");
const spec = @import("spec.zig");

pub const defaultMeterVersion = "0.1.0";

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
            .instruments = std.StringHashMap(pb_metrics.Metric).init(self.allocator),
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

    fn meterExistsWithDifferentAttributes(self: *Self, identifier: u64, attributes: ?pb_common.KeyValueList) bool {
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
    attributes: ?pb_common.KeyValueList = null,
};

/// Meter is a named instance that is used to record measurements.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#meter
const Meter = struct {
    name: []const u8,
    version: []const u8,
    schema_url: ?[]const u8,
    attributes: ?pb_common.KeyValueList,
    instruments: std.StringHashMap(pb_metrics.Metric),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new Counter instrument using the specified type as the value type.
    /// Options to identify the counter must be provided: a mandatory name,
    /// and optional description and unit.
    pub fn createCounter(self: *Self, comptime T: type, options: InstrumentOptions) !Counter(T) {
        switch (T) {
            isize, i8, i16, i32, i64, f32, f64 => {},
            else => @compileError("Unsupported counter value type for monotonic counter"),
        }

        const counter = try Counter(T).init(options, self.allocator);
        // FIXME double registration?
        try self.instruments.put(options.name, pb_metrics.Metric{
            .name = .{ .Const = options.name },
            .unit = if (options.unit) |u| .{ .Const = u } else .Empty,
            .description = if (options.description) |d| .{ .Const = d } else .Empty,
            .data = .{ .sum = counter.measures },
            // These metadata are optional and can be used to add attributes to describe the metric.
            .metadata = std.ArrayList(pb_common.KeyValue).init(self.allocator),
        });
        return counter;
    }
};

pub const InstrumentOptions = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    // Advisory parameters are in development, we don't support them here.
};

// A Counter is a monotonically increasing value used to record a sum of events.
// See https://opentelemetry.io/docs/specs/otel/metrics/api/#counter
fn Counter(comptime valueType: type) type {
    return struct {
        const Self = @This();

        measures: pb_metrics.Sum,
        options: InstrumentOptions,
        // We should keep track of the current value of the counter for each unique comibination of attribute.
        // At the same time, we don't want to allocate memory for each attribute set that comes in.
        // So we store all the counters in a single array and keep track of the state of each counter.
        cumulative: std.AutoHashMap(u64, valueType),

        fn init(options: InstrumentOptions, allocator: std.mem.Allocator) !Self {
            // Validate name, unit anddescription, optionally throw an error if non conformant.
            // See https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-name-syntax
            try spec.validateInstrumentOptions(options);
            return Self{
                .options = options,
                .measures = pb_metrics.Sum{
                    .data_points = std.ArrayList(pb_metrics.NumberDataPoint).init(allocator),
                    .is_monotonic = true,
                    .aggregation_temporality = pb_metrics.AggregationTemporality.AGGREGATION_TEMPORALITY_CUMULATIVE,
                },
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
