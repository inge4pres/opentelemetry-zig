const std = @import("std");
const metrics = @import("metrics.zig");
const pb_common = @import("opentelemetry/proto/common/v1.pb.zig");
const spec = @import("spec.zig");

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

    const meter = try mp.getMeter(.{ .name = meter_name, .version = meter_version });
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

    const meter = try mp.getMeter(.{ .name = meter_name, .version = meter_version, .schema_url = "http://foo.bar", .attributes = attributes });
    std.debug.assert(std.mem.eql(u8, meter.name, meter_name));
    std.debug.assert(std.mem.eql(u8, meter.version, meter_version));
    std.debug.assert(std.mem.eql(u8, meter.schema_url.?, "http://foo.bar"));
    std.debug.assert(meter.attributes.?.values.items.len == attributes.values.items.len);
}

test "meter has default version when creted with no options" {
    const mp = try metrics.MeterProvider.default();
    defer mp.deinit();

    const meter = try mp.getMeter(.{ .name = "ameter" });
    std.debug.assert(std.mem.eql(u8, meter.version, metrics.defaultMeterVersion));
}

test "instrument name must conform to the OpenTelemetry specification" {
    const mp = try metrics.MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    const invalid_names = &[_][]const u8{
        // Does not start with a letter
        "123",
        // null or empty string
        "",
        // contains invalid characters
        "alpha-?",
    };
    for (invalid_names) |name| {
        const r = meter.createCounter(i32, .{ .name = name });
        try std.testing.expectError(spec.FormatError.InvalidName, r);
    }
}

test "meter can create counter instrument and record counter increase without attributes" {
    const mp = try metrics.MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(i32, .{ .name = "a-counter" });

    try counter.add(10, null);
    std.debug.assert(counter.series().count() == 1);
}

test "meter can create counter instrument and record counter increase with attributes" {
    const mp = try metrics.MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(i32, .{
        .name = "a-counter",
        .description = "a funny counter",
        .unit = "KiB",
    });

    try counter.add(1, null);
    std.debug.assert(counter.series().count() == 1);

    var attrs = std.ArrayList(pb_common.KeyValue).init(std.testing.allocator);
    defer attrs.deinit();
    try attrs.append(pb_common.KeyValue{ .key = .{ .Const = "some-key" }, .value = pb_common.AnyValue{ .value = .{ .string_value = .{ .Const = "42" } } } });
    try attrs.append(pb_common.KeyValue{ .key = .{ .Const = "another-key" }, .value = pb_common.AnyValue{ .value = .{ .int_value = 0x123456789 } } });

    try counter.add(2, pb_common.KeyValueList{ .values = attrs });
    std.debug.assert(counter.series().count() == 2);
}
