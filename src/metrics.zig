const std = @import("std");
const pb_common = @import("opentelemetry/proto/common/v1.pb.zig");

pub const defaultMeterVersion = "0.1.0";

pub const MeterProvider = struct {
    allocator: std.mem.Allocator,
    meters: std.StringHashMap(Meter),

    const Self = @This();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    /// Create a new custom meter provider
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

    /// Delete the meter provider
    pub fn deinit(self: *Self) void {
        self.meters.deinit();
        self.allocator.destroy(self);
    }

    /// Get a new meter by specifying its name, version, schemaURL, and attributes.
    /// SchemaURL and attributes are optional and defaults to null.
    /// If a meter with the same name already exists, it will be returned.
    pub fn get_meter(self: *Self, name: []const u8, opts: MeterOptions) !*Meter {
        const i = Meter{
            .name = name,
            .version = opts.version,
            .attributes = opts.attributes,
            .schema_url = opts.schema_url,
        };
        const meter = try self.meters.getOrPutValue(name, i);

        return meter.value_ptr;
    }
};

const MeterOptions = struct {
    version: []const u8 = defaultMeterVersion,
    schema_url: ?[]const u8 = null,
    attributes: ?pb_common.KeyValueList = null,
};

const Meter = struct {
    name: []const u8,
    version: []const u8,
    schema_url: ?[]const u8,
    attributes: ?pb_common.KeyValueList,
};
