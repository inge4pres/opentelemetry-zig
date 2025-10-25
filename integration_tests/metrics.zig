const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const common = @import("common.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var ctx = try common.setupTestContext(allocator, "metrics");
    defer common.cleanupTestContext(&ctx);

    // Run metrics test
    std.debug.print("Running metrics integration test...\n", .{});
    try testMetrics(allocator, ctx.tmp_dir);
    std.debug.print("✓ Metrics test passed\n\n", .{});

    // Run compression test
    std.debug.print("Running metrics compression test...\n", .{});
    try testMetricsWithCompression(allocator, ctx.tmp_dir);
    std.debug.print("✓ Metrics compression test passed\n\n", .{});
}

fn testMetrics(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    // Configure the OTLP exporter to use the collector
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Configure to use HTTP on port 4318 (the collector's HTTP port)
    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;

    // Create meter provider and exporter
    const mp = try metrics_sdk.MeterProvider.default();
    defer mp.shutdown();

    const me = try metrics_sdk.MetricExporter.OTLP(allocator, null, null, config);
    defer me.otlp.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, me.exporter);
    try mp.addReader(mr);

    // Record test metrics
    const meter = try mp.getMeter(.{ .name = "integration-test" });
    var counter = try meter.createCounter(u64, .{ .name = "test_counter" });

    // Record some data points
    const num_data_points = 5;
    for (0..num_data_points) |i| {
        try counter.add(42, .{ "iteration", @as(u64, i) });
    }

    // Force collection and export
    try mr.collect();

    // Give the collector some time to process and write the file
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Validate that the collector received the metrics by reading the JSON file
    std.debug.print("  Successfully sent {d} metric data points\n", .{num_data_points});
    std.debug.print("  Waiting for metrics JSON file...\n", .{});

    try common.waitForFile(tmp_dir, "metrics.json", 10);

    const json_content = try common.readJsonFile(allocator, tmp_dir, "metrics.json");
    defer allocator.free(json_content);

    // Verify the JSON contains expected metric data
    const has_test_counter = std.mem.indexOf(u8, json_content, "test_counter") != null;
    const has_resource_metrics = std.mem.indexOf(u8, json_content, "resourceMetrics") != null or
        std.mem.indexOf(u8, json_content, "resource_metrics") != null;

    if (!has_test_counter or !has_resource_metrics) {
        std.debug.print("  ERROR: Metrics JSON doesn't contain expected data\n", .{});
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.MetricsNotReceivedByCollector;
    }

    std.debug.print("  ✓ Metrics JSON validated - found 'test_counter' metric\n", .{});
}

fn testMetricsWithCompression(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    // Configure the OTLP exporter with gzip compression
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Enable gzip compression
    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;
    config.compression = .gzip;

    // Create meter provider and exporter
    const mp = try metrics_sdk.MeterProvider.default();
    defer mp.shutdown();

    const me = try metrics_sdk.MetricExporter.OTLP(allocator, null, null, config);
    defer me.otlp.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, me.exporter);
    try mp.addReader(mr);

    // Record test metrics with compression indicator
    const meter = try mp.getMeter(.{ .name = "integration-test-compression" });
    var counter = try meter.createCounter(u64, .{ .name = "test_counter_compressed" });

    // Record some data points
    const num_data_points = 5;
    for (0..num_data_points) |i| {
        try counter.add(100 + i, .{ "compression", @as([]const u8, "gzip"), "iteration", @as(u64, i) });
    }

    // Force collection and export
    try mr.collect();

    // Give the collector time to process
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Wait for the file with expected content
    std.debug.print("  Successfully sent {d} compressed metric data points\n", .{num_data_points});
    std.debug.print("  Waiting for metrics JSON file with compressed data...\n", .{});

    const json_content = common.waitForFileContent(allocator, tmp_dir, "metrics.json", "test_counter_compressed", 15) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            // Read the file to show what we got instead
            const stale_content = common.readJsonFile(allocator, tmp_dir, "metrics.json") catch {
                std.debug.print("  ERROR: Could not read metrics.json\n", .{});
                return error.CompressedMetricsNotReceivedByCollector;
            };
            defer allocator.free(stale_content);
            std.debug.print("  ERROR: Compressed metrics JSON doesn't contain expected data\n", .{});
            std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{stale_content[0..@min(stale_content.len, 500)]});
            return error.CompressedMetricsNotReceivedByCollector;
        }
        return err;
    };
    defer allocator.free(json_content);

    // Verify the JSON contains expected compressed metric data
    const has_compressed_counter = std.mem.indexOf(u8, json_content, "test_counter_compressed") != null;
    const has_compression_attr = std.mem.indexOf(u8, json_content, "gzip") != null;
    const has_resource_metrics = std.mem.indexOf(u8, json_content, "resourceMetrics") != null or
        std.mem.indexOf(u8, json_content, "resource_metrics") != null;

    if (!has_compressed_counter or !has_resource_metrics) {
        std.debug.print("  ERROR: Compressed metrics JSON doesn't contain expected data\n", .{});
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.CompressedMetricsNotReceivedByCollector;
    }

    std.debug.print("  ✓ Compressed metrics JSON validated - found 'test_counter_compressed' metric\n", .{});
    if (has_compression_attr) {
        std.debug.print("  ✓ Compression attribute 'gzip' found in metrics\n", .{});
    }
}
