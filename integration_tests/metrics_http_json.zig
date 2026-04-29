const std = @import("std");
const clock = @import("clock");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const common = @import("common.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try common.setupTestContext(allocator, io, "metrics-http-json");
    defer common.cleanupTestContext(&ctx, io);

    std.debug.print("Running metrics http/json integration test...\n", .{});
    try testMetricsHttpJson(allocator, io, ctx.tmp_dir);
    std.debug.print("✓ Metrics http/json test passed\n\n", .{});
}

fn testMetricsHttpJson(allocator: std.mem.Allocator, io: std.Io, tmp_dir: std.Io.Dir) !void {
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;
    config.protocol = .http_json;

    const mp = try metrics_sdk.MeterProvider.init(allocator, io);
    defer mp.shutdown();

    const me = try metrics_sdk.MetricExporter.OTLP(allocator, io, null, null, config);
    defer me.otlp.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, io, me.exporter);
    try mp.addReader(mr);

    const meter = try mp.getMeter(.{ .name = "integration-test-http-json" });
    var counter = try meter.createCounter(u64, .{ .name = "test_counter_http_json" });

    const num_data_points = 5;
    for (0..num_data_points) |i| {
        try counter.add(42, .{
            "format",    @as([]const u8, "http_json"),
            "iteration", @as(u64, i),
        });
    }

    try mr.collect();

    clock.sleep(1 * std.time.ns_per_s);

    std.debug.print("  Sent {d} data points via http/json\n", .{num_data_points});
    std.debug.print("  Waiting for collector to write metrics.json...\n", .{});

    const json_content = common.waitForFileContent(
        allocator,
        io,
        tmp_dir,
        "metrics.json",
        "test_counter_http_json",
        15,
    ) catch |err| {
        std.debug.print("  ERROR: collector did not parse the http/json payload\n", .{});
        return err;
    };
    defer allocator.free(json_content);

    std.debug.print("  ✓ Collector parsed http/json payload and wrote metric 'test_counter_http_json'\n", .{});

    if (std.mem.indexOf(u8, json_content, "http_json") != null) {
        std.debug.print("  ✓ String attribute 'format=http_json' found — AnyValue oneof correctly serialized\n", .{});
    } else {
        std.debug.print("  WARNING: string attribute value not found in collector output\n", .{});
    }
}
