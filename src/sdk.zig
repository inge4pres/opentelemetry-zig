const std = @import("std");
const pb_common = @import("opentelemetry/proto/common/v1.pb.zig");
pub const metrics = @import("metrics.zig");

test "default meter provider can be fetched" {
    const mp = try metrics.MeterProvider.default();
    defer mp.deinit();

    std.debug.assert(@intFromPtr(&mp) != 0);
}

test "custom meter provider can be created" {
    const mp = try metrics.MeterProvider.init(std.testing.allocator);
    defer mp.deinit();

    std.debug.assert(@intFromPtr(&mp) != 0);
}

test "meter can be created from custom provider" {
    const meter_name = "my-meter";
    const meter_version = "my-meter";
    const mp = try metrics.MeterProvider.init(std.testing.allocator);
    defer mp.deinit();

    const meter = try mp.get_meter(meter_name, .{ .version = meter_version });
    std.debug.assert(std.mem.eql(u8, meter.name, meter_name));
    std.debug.assert(std.mem.eql(u8, meter.version, meter_version));
    std.debug.assert(meter.schema_url == null);
    std.debug.assert(meter.attributes == null);
}

test "meter can be created from default provider with schema url and attributes" {
    const meter_name = "my-meter";
    const meter_version = "my-meter";
    const attributes = pb_common.KeyValueList{ .values = std.ArrayList(pb_common.KeyValue).init(std.testing.allocator) };
    const mp = try metrics.MeterProvider.default();
    defer mp.deinit();

    const meter = try mp.get_meter(meter_name, .{ .version = meter_version, .schema_url = "http://foo.bar", .attributes = attributes });
    std.debug.assert(std.mem.eql(u8, meter.name, meter_name));
    std.debug.assert(std.mem.eql(u8, meter.version, meter_version));
    std.debug.assert(std.mem.eql(u8, meter.schema_url.?, "http://foo.bar"));
    std.debug.assert(meter.attributes.?.values.items.len == attributes.values.items.len);
}

test "meter has default version when creted with no options" {
    const meter_name = "my-meter";
    const mp = try metrics.MeterProvider.default();
    defer mp.deinit();

    const meter = try mp.get_meter(meter_name, .{});
    std.debug.assert(std.mem.eql(u8, meter.version, metrics.defaultMeterVersion));
}
