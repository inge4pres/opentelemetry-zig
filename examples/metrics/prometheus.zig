const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const MeterProvider = metrics_sdk.MeterProvider;
const MetricExporter = metrics_sdk.MetricExporter;
const PeriodicExportingReader = metrics_sdk.PeriodicExportingReader;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the meter provider
    const mp = try MeterProvider.init(allocator);
    defer mp.shutdown();

    // Create Prometheus exporter using factory function
    const result = try MetricExporter.Prometheus(allocator, .{
        .host = "127.0.0.1",
        .port = 9464,
    });
    defer {
        result.prometheus.deinit();
        result.exporter.shutdown();
    }

    // Start HTTP server
    try result.prometheus.start();
    defer result.prometheus.stop();

    // Create a periodic reader that collects metrics every 5 seconds
    const periodic_reader = try PeriodicExportingReader.init(
        allocator,
        mp,
        result.exporter,
        5000, // collect every 5 seconds
        null,
    );
    defer periodic_reader.shutdown();

    // Create a meter
    const meter = try mp.getMeter(.{
        .name = "example.prometheus",
        .version = "1.0",
    });

    // Create some metrics
    const request_counter = try meter.createCounter(u64, .{
        .name = "http_requests",
        .description = "Total HTTP requests",
    });

    const active_connections = try meter.createGauge(i64, .{
        .name = "active_connections",
        .description = "Number of active connections",
    });

    const request_duration = try meter.createHistogram(f64, .{
        .name = "request_duration",
        .description = "Request duration in seconds",
        .unit = "s",
    });

    std.log.info("Prometheus exporter started on http://127.0.0.1:9464/metrics", .{});
    std.log.info("Metrics are collected and cached every 5 seconds", .{});
    std.log.info("Press Ctrl+C to stop, or wait 30 seconds...", .{});

    // Simulate some metrics for 30 seconds
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        // Increment request counter with different paths
        try request_counter.add(1, .{ "path", @as([]const u8, "/api/users"), "method", @as([]const u8, "GET") });
        try request_counter.add(1, .{ "path", @as([]const u8, "/api/posts"), "method", @as([]const u8, "POST") });

        // Update active connections
        const connections: i64 = @intCast(10 + @mod(i, 5));
        try active_connections.record(connections, .{});

        // Record request duration
        const duration = 0.01 + @as(f64, @floatFromInt(@mod(i, 100))) / 1000.0;
        try request_duration.record(duration, .{ "path", @as([]const u8, "/api/users") });

        std.Thread.sleep(1 * std.time.ns_per_s);
    }

    std.log.info("Example completed.", .{});
}
