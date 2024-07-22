const std = @import("std");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pb_common = @import("opentelemetry/proto/common/v1.pb.zig");
const pb_metrics = @import("opentelemetry/proto/metrics/v1.pb.zig");
const pbutils = @import("pb_utils.zig");

pub const defaultMeterVersion = "0.1.0";

/// MeterProvider is responsble for creating and managing meters.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#meterprovider
pub const MeterProvider = struct {
    allocator: std.mem.Allocator,
    meters: std.StringHashMap(Meter),

    const Self = @This();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    /// Create a new custom meter provider, using the specified allocator.
    pub fn init(alloc: std.mem.Allocator) !*Self {
        const provider = try alloc.create(Self);
        provider.* = Self{
            .allocator = alloc,
            .meters = std.StringHashMap(Meter).init(alloc),
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
    pub fn get_meter(self: *Self, name: []const u8, opts: MeterOptions) !*Meter {
        const i = Meter{
            // TODO validate name before assignment here, optionally throw an error if non conformant.
            // See https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-name-syntax
            .name = name,
            .version = opts.version,
            .attributes = opts.attributes,
            .schema_url = opts.schema_url,
            .instruments = std.StringHashMap(pb_metrics.Metric).init(self.allocator),
            .allocator = self.allocator,
        };
        const meter = try self.meters.getOrPutValue(name, i);

        return meter.value_ptr;
    }
};

pub const MeterOptions = struct {
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
    pub fn create_counter(self: *Self, comptime T: type, name: []const u8, options: InstrumentOptions) !Counter(T) {
        const counter = try Counter(T).init(name, options, self.allocator);
        try self.instruments.put(name, pb_metrics.Metric{
            .name = .{ .Const = name },
            .unit = if (options.unit) |u| .{ .Const = u } else .Empty,
            .description = if (options.description) |d| .{ .Const = d } else .Empty,
            .data = .{ .sum = counter.measures },
            // These metadata are optional and can be used to add attributes to describe the metric.
            .metadata = std.ArrayList(pb_common.KeyValue).init(self.allocator),
        });
        return counter;
    }
};

const InstrumentOptions = struct {
    description: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    // Advisory parameters are in development, we don't support them here.
};

fn Counter(comptime valueType: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        measures: pb_metrics.Sum,
        options: InstrumentOptions,
        // We should keep track of the current value of the counter for each unique comibination of attribute.
        // At the same time, we don't want to allocate memory for each attribute set that comes in.
        // So we store all the counters in a single array and keep track of the state of each counter.
        cumulative: std.AutoHashMap(u64, valueType),
        allocator: std.mem.Allocator,

        fn init(name: []const u8, options: InstrumentOptions, allocator: std.mem.Allocator) !Self {
            return Self{
                .name = name,
                .measures = pb_metrics.Sum{
                    .data_points = std.ArrayList(pb_metrics.NumberDataPoint).init(allocator),
                    .is_monotonic = true,
                    .aggregation_temporality = pb_metrics.AggregationTemporality.AGGREGATION_TEMPORALITY_CUMULATIVE,
                },
                .options = options,
                .cumulative = std.AutoHashMap(u64, valueType).init(allocator),
                .allocator = allocator,
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
