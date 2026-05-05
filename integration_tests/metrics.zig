const std = @import("std");
const clock = @import("clock");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var ctx = try common.setupTestContext(allocator, io, "metrics");
    defer common.cleanupTestContext(&ctx, io);

    std.debug.print("Running metrics integration test...\n", .{});
    try testMetrics(allocator, io, init.environ_map, ctx.tmp_dir);
    std.debug.print("✓ Metrics test passed\n\n", .{});

    std.debug.print("Running metrics compression test...\n", .{});
    try testMetricsWithCompression(allocator, io, init.environ_map, ctx.tmp_dir);
    std.debug.print("✓ Metrics compression test passed\n\n", .{});
}

fn testMetrics(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    tmp_dir: std.Io.Dir,
) !void {
    var config = try sdk.otlp.ConfigOptions.init(allocator, env_map);
    defer config.deinit();

    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;

    const mp = try metrics_sdk.MeterProvider.init(allocator, io);
    defer mp.shutdown();

    const me = try metrics_sdk.MetricExporter.OTLP(allocator, io, null, null, config);
    defer me.otlp.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, io, me.exporter);
    // mr.shutdown() also shuts down me.exporter (the MetricExporter wrapper).
    defer mr.shutdown();
    try mp.addReader(mr);

    const meter = try mp.getMeter(.{ .name = "integration-test" });
    var counter = try meter.createCounter(u64, .{ .name = "test_counter" });

    const num_data_points = 5;
    for (0..num_data_points) |i| {
        try counter.add(42, .{ "iteration", @as(u64, i) });
    }

    try mr.collect();

    clock.sleep(1 * std.time.ns_per_s);

    std.debug.print("  Successfully sent {d} metric data points\n", .{num_data_points});
    std.debug.print("  Waiting for metrics JSON file...\n", .{});

    try common.waitForFile(io, tmp_dir, "metrics.json", 10);

    const json_content = try common.readJsonFile(allocator, io, tmp_dir, "metrics.json");
    defer allocator.free(json_content);

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

fn testMetricsWithCompression(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    tmp_dir: std.Io.Dir,
) !void {
    var config = try sdk.otlp.ConfigOptions.init(allocator, env_map);
    defer config.deinit();

    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;
    config.compression = .gzip;

    const mp = try metrics_sdk.MeterProvider.init(allocator, io);
    defer mp.shutdown();

    const me = try metrics_sdk.MetricExporter.OTLP(allocator, io, null, null, config);
    defer me.otlp.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, io, me.exporter);
    // mr.shutdown() also shuts down me.exporter (the MetricExporter wrapper).
    defer mr.shutdown();
    try mp.addReader(mr);

    const meter = try mp.getMeter(.{ .name = "integration-test-compression" });
    var counter = try meter.createCounter(u64, .{ .name = "test_counter_compressed" });

    const num_data_points = 5;
    for (0..num_data_points) |i| {
        try counter.add(100 + i, .{ "compression", @as([]const u8, "gzip"), "iteration", @as(u64, i) });
    }

    try mr.collect();

    clock.sleep(1 * std.time.ns_per_s);

    std.debug.print("  Successfully sent {d} compressed metric data points\n", .{num_data_points});
    std.debug.print("  Waiting for metrics JSON file with compressed data...\n", .{});

    const json_content = common.waitForFileContent(allocator, io, tmp_dir, "metrics.json", "test_counter_compressed", 15) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            const stale_content = common.readJsonFile(allocator, io, tmp_dir, "metrics.json") catch {
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
