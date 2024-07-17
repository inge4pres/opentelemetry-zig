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
    pub fn get_meter(self: *Self, name: []const u8, version: ?[]const u8, schemaURL: ?[]const u8, attributes: ?pb_common.KeyValueList) !*Meter {
        const i = Meter{
            .name = name,
            .version = version orelse defaultMeterVersion,
            .schema_url = schemaURL,
            .attributes = attributes,
        };
        const meter = try self.meters.getOrPutValue(name, i);

        return meter.value_ptr;
    }
};

const Meter = struct {
    name: []const u8,
    version: []const u8,
    schema_url: ?[]const u8,
    attributes: ?pb_common.KeyValueList,
};
