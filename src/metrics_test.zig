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

test "getting same meter with different attributes returns an error" {
    const name = "my-meter";
    const version = "v1.2.3";
    const schema_url = "http://foo.bar";
    var attributes = pb_common.KeyValueList{ .values = std.ArrayList(pb_common.KeyValue).init(std.testing.allocator) };
    defer attributes.values.deinit();
    try attributes.values.append(pb_common.KeyValue{ .key = .{ .Const = "key" }, .value = pb_common.AnyValue{ .value = .{ .string_value = .{ .Const = "value" } } } });

    const mp = try metrics.MeterProvider.default();
    _ = try mp.getMeter(.{ .name = name, .version = version, .schema_url = schema_url, .attributes = attributes });
    // modify the attributes adding one
    try attributes.values.append(pb_common.KeyValue{ .key = .{ .Const = "key2" }, .value = pb_common.AnyValue{ .value = .{ .string_value = .{ .Const = "value2" } } } });

    const r = mp.getMeter(.{ .name = name, .version = version, .schema_url = schema_url, .attributes = attributes });
    try std.testing.expectError(spec.ResourceError.MeterExistsWithDifferentAttributes, r);
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

test "meter can create histogram instrument and record histogram increase without buckets" {
    const mp = try metrics.MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(i32, .{ .name = "anything" });

    try histogram.record(1, null);
    try histogram.record(5, null);
    try histogram.record(15, null);

    try std.testing.expectEqual(.{ 1, 15 }, histogram.minAndMax());
    std.debug.assert(histogram.series().count() == 1);
    const counts = histogram.bucketCounts(null).?;
    std.debug.assert(counts.len == spec.defaultHistogramBucketBoundaries.len);
    const expected_counts = &[_]usize{ 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(usize, expected_counts, counts);
}

test "meter can create histogram instrument and record histogram increase with explicit buckets" {
    const mp = try metrics.MeterProvider.default();
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(i32, .{ .name = "a-histogram", .explicitBuckets = &.{ 1.0, 10.0, 100.0, 1000.0 } });

    try histogram.record(1, null);
    try histogram.record(5, null);
    try histogram.record(15, null);

    try std.testing.expectEqual(.{ 1, 15 }, histogram.minAndMax());
    std.debug.assert(histogram.series().count() == 1);
    const counts = histogram.bucketCounts(null).?;
    std.debug.assert(counts.len == 4);
    const expected_counts = &[_]usize{ 1, 1, 1, 0 };
    try std.testing.expectEqualSlices(usize, expected_counts, counts);
}
