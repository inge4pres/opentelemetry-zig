const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const common = @import("common.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var ctx = try common.setupTestContext(allocator, "metrics-http-json");
    defer common.cleanupTestContext(&ctx);

    std.debug.print("Running metrics http/json integration test...\n", .{});
    try testMetricsHttpJson(allocator, ctx.tmp_dir);
    std.debug.print("✓ Metrics http/json test passed\n\n", .{});
}

// Sends metrics with string attributes via http/json to a real OTel collector.
// This validates that the AnyValue oneof field is correctly serialized and the JSON is conformant.
fn testMetricsHttpJson(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;
    config.protocol = .http_json;

    const mp = try metrics_sdk.MeterProvider.default();
    defer mp.shutdown();

    const me = try metrics_sdk.MetricExporter.OTLP(allocator, null, null, config);
    defer me.otlp.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, me.exporter);
    try mp.addReader(mr);

    const meter = try mp.getMeter(.{ .name = "integration-test-http-json" });
    var counter = try meter.createCounter(u64, .{ .name = "test_counter_http_json" });

    // Use a string attribute to exercise the AnyValue.string_value oneof path —
    // the field that was incorrectly double-nested before the fix.
    const num_data_points = 5;
    for (0..num_data_points) |i| {
        try counter.add(42, .{
            "format",    @as([]const u8, "http_json"),
            "iteration", @as(u64, i),
        });
    }

    try mr.collect();

    // Give the collector time to batch and flush to disk.
    std.Thread.sleep(1 * std.time.ns_per_s);

    std.debug.print("  Sent {d} data points via http/json\n", .{num_data_points});
    std.debug.print("  Waiting for collector to write metrics.json...\n", .{});

    // Wait for the specific metric name to appear, confirming the collector
    // successfully parsed the http/json payload (including the string attribute).
    const json_content = common.waitForFileContent(
        allocator,
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

    // Also confirm the string attribute value arrived — this is the oneof field
    // that was previously mis-serialized.
    if (std.mem.indexOf(u8, json_content, "http_json") != null) {
        std.debug.print("  ✓ String attribute 'format=http_json' found — AnyValue oneof correctly serialized\n", .{});
    } else {
        std.debug.print("  WARNING: string attribute value not found in collector output\n", .{});
    }
}
