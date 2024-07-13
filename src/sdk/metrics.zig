const std = @import("std");
const pb_common = @import("pbcommonv1");
// const pb_resource = @import("../../model/opentelemetry/proto/resource/v1.pb.zig");

pub const MeterProvider = struct {
    const self = @This();

    name: []const u8,
    version: []const u8,
    schema_url: ?[]const u8,
    attributes: ?pb_common.KeyValueList,

    allocator: std.mem.Allocator = std.heap.GeneralPurposeAllocator(.{}),

    var instruments = std.AutoHashMap([]const u8, *Meter).init(self.allocator);

    /// Create a new custom meter provider
    pub fn init(name: []const u8, version: ?[]const u8, schemaURL: ?[]const u8, attributes: ?pb_common.KeyValueList) MeterProvider {
        return MeterProvider{
            .name = name,
            .version = version,
            .schema_url = schemaURL,
            .attributes = attributes,
        };
    }

    /// Use the default MeterProvider
    pub fn default() MeterProvider {
        return MeterProvider.init("io.opentelemetry.sdk.metrics", "0.1.0", null, null);
    }

    /// Get a meter by specifying its type
    pub fn meter(comptime T: type) !T {
        const i = struct {
            .instrument = T,
        };
        try self.instruments.addOne(i);
        return i;
    }
};

pub const MeterType = enum {
    COUNTER,
    UPDOWNCOUNTER,
    ASYNC_UPDOWNCOUNTER,
    ASYNC_COUNTER,
    HISTOGRAM,
    GAUGE,
    ASYNC_GAUGE,
};

pub const Meter = struct { kind: MeterType };


