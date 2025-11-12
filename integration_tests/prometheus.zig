const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const MeterProvider = metrics_sdk.MeterProvider;
const MetricExporter = metrics_sdk.MetricExporter;
const MetricReader = metrics_sdk.MetricReader;

/// Integration test for the Prometheus exporter.
/// Tests the HTTP server and Prometheus text format output.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    }
    const allocator = gpa.allocator();

    std.log.info("Starting Prometheus exporter integration test...", .{});

    // Run test with a unique port to avoid conflicts
    const port: u16 = 19464; // Different from default 9464

    try testPrometheusExporter(allocator, port);

    std.log.info("✓ All Prometheus exporter tests passed!", .{});
}

fn testPrometheusExporter(allocator: std.mem.Allocator, port: u16) !void {
    // Step 1: Create meter provider
    const mp = try MeterProvider.init(allocator);
    defer mp.shutdown();

    // Step 2: Create Prometheus exporter using factory function
    const result = try MetricExporter.Prometheus(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .formatter_config = .{
            .naming_convention = .UnderscoreEscapingWithSuffixes,
            .include_scope_labels = true,
        },
    });
    // Shutdown in correct order: reader first, then prometheus exporter, then metric exporter
    defer result.exporter.shutdown();
    defer result.prometheus.deinit();

    // Step 3: Create metric reader and register with MeterProvider
    const reader = try MetricReader.init(allocator, result.exporter);
    defer reader.shutdown();
    try mp.addReader(reader);

    // Step 4: Start HTTP server
    try result.prometheus.start();
    defer result.prometheus.stop();

    std.log.info("✓ Prometheus exporter started on port {d}", .{port});

    // Wait for server to be ready
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Step 5: Create a meter and instruments
    const meter = try mp.getMeter(.{
        .name = "integration.test.prometheus",
        .version = "1.0.0",
    });

    const request_counter = try meter.createCounter(u64, .{
        .name = "http_requests",
        .description = "Total HTTP requests",
    });

    const temperature_gauge = try meter.createGauge(f64, .{
        .name = "temperature",
        .description = "Temperature in Celsius",
        .unit = "C",
    });

    const response_time = try meter.createHistogram(f64, .{
        .name = "response_time",
        .description = "Response time",
        .unit = "s",
    });

    // Step 6: Record some metrics
    try request_counter.add(10, .{ "path", @as([]const u8, "/api/users"), "method", @as([]const u8, "GET") });
    try request_counter.add(5, .{ "path", @as([]const u8, "/api/posts"), "method", @as([]const u8, "POST") });
    try temperature_gauge.record(23.5, .{ "location", @as([]const u8, "office") });
    try response_time.record(0.015, .{ "endpoint", @as([]const u8, "/api/users") });
    try response_time.record(0.025, .{ "endpoint", @as([]const u8, "/api/users") });
    try response_time.record(0.012, .{ "endpoint", @as([]const u8, "/api/posts") });

    std.log.info("✓ Test metrics recorded", .{});

    // Step 7: Collect metrics to cache them in the Prometheus exporter
    try reader.collect();
    std.log.info("✓ Metrics collected and cached", .{});

    // Step 8: Make HTTP request to /metrics endpoint
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/metrics", .{port});
    defer allocator.free(url);

    var response_body = std.array_list.Managed(u8).init(allocator);
    defer response_body.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", port);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    // Send HTTP GET request
    const request = "GET /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    try stream.writeAll(request);

    // Read response
    var buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    while (true) {
        const n = stream.read(&buf) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) break;
        try response_body.appendSlice(buf[0..n]);
        total_read += n;
    }

    const response = response_body.items;
    std.log.info("✓ Received HTTP response ({d} bytes)", .{total_read});

    // Step 9: Validate response
    try validateHttpResponse(response);
    std.log.info("✓ HTTP response format validated", .{});

    // Step 10: Validate Prometheus format
    const body = extractHttpBody(response) orelse return error.NoHttpBody;
    try validatePrometheusFormat(body);
    std.log.info("✓ Prometheus format validated", .{});

    // Step 11: Validate metric content
    try validateMetricContent(body);
    std.log.info("✓ Metric content validated", .{});

    // Step 12: Test 404 for invalid paths
    try test404Response(allocator, port);
    std.log.info("✓ 404 response validated", .{});
}

fn validateHttpResponse(response: []const u8) !void {
    // Check HTTP status line
    if (!std.mem.startsWith(u8, response, "HTTP/1.1 200 OK")) {
        std.log.err("Expected HTTP 200 OK, got: {s}", .{response[0..@min(50, response.len)]});
        return error.InvalidHttpStatus;
    }

    // Check Content-Type header
    if (std.mem.indexOf(u8, response, "Content-Type: text/plain; version=0.0.4")) |_| {
        // Found correct content type
    } else {
        std.log.err("Missing or incorrect Content-Type header", .{});
        return error.InvalidContentType;
    }
}

fn extractHttpBody(response: []const u8) ?[]const u8 {
    // HTTP body starts after "\r\n\r\n"
    if (std.mem.indexOf(u8, response, "\r\n\r\n")) |pos| {
        return response[pos + 4 ..];
    }
    return null;
}

fn validatePrometheusFormat(body: []const u8) !void {
    // Check for HELP lines
    if (std.mem.indexOf(u8, body, "# HELP")) |_| {
        // Good
    } else {
        std.log.err("Missing # HELP lines in Prometheus output", .{});
        return error.MissingHelpLines;
    }

    // Check for TYPE lines
    if (std.mem.indexOf(u8, body, "# TYPE")) |_| {
        // Good
    } else {
        std.log.err("Missing # TYPE lines in Prometheus output", .{});
        return error.MissingTypeLines;
    }
}

fn validateMetricContent(body: []const u8) !void {
    // Validate counter with _total suffix
    if (std.mem.indexOf(u8, body, "http_requests_total{")) |_| {
        std.log.info("  ✓ Found http_requests_total counter", .{});
    } else {
        std.log.err("Missing http_requests_total in output", .{});
        return error.MissingCounter;
    }

    // Validate counter has labels
    if (std.mem.indexOf(u8, body, "path=\"/api/users\"")) |_| {
        std.log.info("  ✓ Found path label", .{});
    } else {
        std.log.err("Missing path label in counter", .{});
        return error.MissingLabels;
    }

    if (std.mem.indexOf(u8, body, "method=\"GET\"")) |_| {
        std.log.info("  ✓ Found method label", .{});
    } else {
        std.log.err("Missing method label in counter", .{});
        return error.MissingLabels;
    }

    // Validate scope labels are included
    if (std.mem.indexOf(u8, body, "otel_scope_name=\"integration.test.prometheus\"")) |_| {
        std.log.info("  ✓ Found scope name label", .{});
    } else {
        std.log.err("Missing otel_scope_name label", .{});
        return error.MissingScopeLabels;
    }

    // Validate gauge (no suffix for gauge)
    if (std.mem.indexOf(u8, body, "temperature_C{")) |_| {
        std.log.info("  ✓ Found temperature_C gauge", .{});
    } else {
        std.log.err("Missing temperature_C gauge", .{});
        return error.MissingGauge;
    }

    // Validate histogram with _bucket, _sum, _count
    if (std.mem.indexOf(u8, body, "response_time_seconds_bucket{")) |_| {
        std.log.info("  ✓ Found histogram buckets", .{});
    } else {
        std.log.err("Missing response_time_seconds_bucket", .{});
        return error.MissingHistogramBucket;
    }

    if (std.mem.indexOf(u8, body, "response_time_seconds_sum")) |_| {
        std.log.info("  ✓ Found histogram sum", .{});
    } else {
        std.log.err("Missing response_time_seconds_sum", .{});
        return error.MissingHistogramSum;
    }

    if (std.mem.indexOf(u8, body, "response_time_seconds_count")) |_| {
        std.log.info("  ✓ Found histogram count", .{});
    } else {
        std.log.err("Missing response_time_seconds_count", .{});
        return error.MissingHistogramCount;
    }

    // Validate histogram has le label
    if (std.mem.indexOf(u8, body, "le=\"")) |_| {
        std.log.info("  ✓ Found le label in histogram", .{});
    } else {
        std.log.err("Missing le label in histogram", .{});
        return error.MissingLeLabel;
    }
}

fn test404Response(allocator: std.mem.Allocator, port: u16) !void {
    _ = allocator;

    const address = try std.net.Address.parseIp("127.0.0.1", port);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    // Request invalid path
    const request = "GET /invalid HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    try stream.writeAll(request);

    // Read response
    var buf: [1024]u8 = undefined;
    const n = try stream.read(&buf);
    const response = buf[0..n];

    // Validate 404 response
    if (!std.mem.startsWith(u8, response, "HTTP/1.1 404")) {
        std.log.err("Expected HTTP 404 for invalid path, got: {s}", .{response[0..@min(50, n)]});
        return error.Expected404;
    }
}
