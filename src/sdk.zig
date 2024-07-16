const std = @import("std");
const pb_common = @import("opentelemetry/proto/common/v1.pb.zig");

pub const metrics = @import("metrics.zig");

test "default meter provider has name and version" {
    const mp = metrics.MeterProvider.default();
    std.debug.assert(std.mem.eql(u8, mp.name, "io.opentelemetry.sdk.metrics"));
}

test "custom meter provider can be configured with attributes" {
    const meter_name = "my-meter";
    const meter_version = "my-meter";
    const attributes = pb_common.KeyValueList{ .values = std.ArrayList(pb_common.KeyValue).init(std.testing.allocator) };
    const mp = metrics.MeterProvider.init(meter_name, meter_version, null, attributes);
    std.debug.assert(std.mem.eql(u8, mp.name, meter_name));
    std.debug.assert(std.mem.eql(u8, mp.version, meter_version));
}
