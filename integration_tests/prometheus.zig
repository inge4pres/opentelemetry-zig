const std = @import("std");
const clock = @import("clock");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const MeterProvider = metrics_sdk.MeterProvider;
const MetricExporter = metrics_sdk.MetricExporter;
const MetricReader = metrics_sdk.MetricReader;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("Starting Prometheus exporter integration test...", .{});

    const port: u16 = 19464;

    try testPrometheusExporter(allocator, io, port);

    std.log.info("✓ All Prometheus exporter tests passed!", .{});
}

fn testPrometheusExporter(allocator: std.mem.Allocator, io: std.Io, port: u16) !void {
    const mp = try MeterProvider.init(allocator, io);
    defer mp.shutdown();

    const result = try MetricExporter.Prometheus(allocator, io, .{
        .host = "127.0.0.1",
        .port = port,
        .formatter_config = .{
            .naming_convention = .UnderscoreEscapingWithSuffixes,
            .include_scope_labels = true,
        },
    });
    defer result.prometheus.deinit();

    const reader = try MetricReader.init(allocator, io, result.exporter);
    // reader.shutdown() also shuts down the underlying MetricExporter.
    defer reader.shutdown();
    try mp.addReader(reader);

    try result.prometheus.start();
    defer result.prometheus.stop();

    std.log.info("✓ Prometheus exporter started on port {d}", .{port});

    clock.sleep(500 * std.time.ns_per_ms);

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

    try request_counter.add(10, .{ "path", @as([]const u8, "/api/users"), "method", @as([]const u8, "GET") });
    try request_counter.add(5, .{ "path", @as([]const u8, "/api/posts"), "method", @as([]const u8, "POST") });
    try temperature_gauge.record(23.5, .{ "location", @as([]const u8, "office") });
    try response_time.record(0.015, .{ "endpoint", @as([]const u8, "/api/users") });
    try response_time.record(0.025, .{ "endpoint", @as([]const u8, "/api/users") });
    try response_time.record(0.012, .{ "endpoint", @as([]const u8, "/api/posts") });

    std.log.info("✓ Test metrics recorded", .{});

    try reader.collect();
    std.log.info("✓ Metrics collected and cached", .{});

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/metrics", .{port});
    defer allocator.free(url);

    var response_body = std.array_list.Managed(u8).init(allocator);
    defer response_body.deinit();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    const request = "GET /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader_stream = stream.reader(io, &read_buffer);
    var buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    while (true) {
        const n = reader_stream.interface.readSliceShort(&buf) catch |err| {
            if (err == error.WouldBlock) {
                clock.sleep(10 * std.time.ns_per_ms);
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

    try validateHttpResponse(response);
    std.log.info("✓ HTTP response format validated", .{});

    const body = extractHttpBody(response) orelse return error.NoHttpBody;
    try validatePrometheusFormat(body);
    std.log.info("✓ Prometheus format validated", .{});

    try validateMetricContent(body);
    std.log.info("✓ Metric content validated", .{});

    try test404Response(allocator, io, port);
    std.log.info("✓ 404 response validated", .{});
}

fn validateHttpResponse(response: []const u8) !void {
    if (!std.mem.startsWith(u8, response, "HTTP/1.1 200 OK")) {
        std.log.err("Expected HTTP 200 OK, got: {s}", .{response[0..@min(50, response.len)]});
        return error.InvalidHttpStatus;
    }

    if (std.mem.indexOf(u8, response, "Content-Type: text/plain; version=0.0.4")) |_| {} else {
        std.log.err("Missing or incorrect Content-Type header", .{});
        return error.InvalidContentType;
    }
}

fn extractHttpBody(response: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, response, "\r\n\r\n")) |pos| {
        return response[pos + 4 ..];
    }
    return null;
}

fn validatePrometheusFormat(body: []const u8) !void {
    if (std.mem.indexOf(u8, body, "# HELP")) |_| {} else {
        std.log.err("Missing # HELP lines in Prometheus output", .{});
        return error.MissingHelpLines;
    }

    if (std.mem.indexOf(u8, body, "# TYPE")) |_| {} else {
        std.log.err("Missing # TYPE lines in Prometheus output", .{});
        return error.MissingTypeLines;
    }
}

fn validateMetricContent(body: []const u8) !void {
    if (std.mem.indexOf(u8, body, "http_requests_total{")) |_| {
        std.log.info("  ✓ Found http_requests_total counter", .{});
    } else {
        std.log.err("Missing http_requests_total in output", .{});
        return error.MissingCounter;
    }

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

    if (std.mem.indexOf(u8, body, "otel_scope_name=\"integration.test.prometheus\"")) |_| {
        std.log.info("  ✓ Found scope name label", .{});
    } else {
        std.log.err("Missing otel_scope_name label", .{});
        return error.MissingScopeLabels;
    }

    if (std.mem.indexOf(u8, body, "temperature_C{")) |_| {
        std.log.info("  ✓ Found temperature_C gauge", .{});
    } else {
        std.log.err("Missing temperature_C gauge", .{});
        return error.MissingGauge;
    }

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

    if (std.mem.indexOf(u8, body, "le=\"")) |_| {
        std.log.info("  ✓ Found le label in histogram", .{});
    } else {
        std.log.err("Missing le label in histogram", .{});
        return error.MissingLeLabel;
    }
}

fn test404Response(allocator: std.mem.Allocator, io: std.Io, port: u16) !void {
    _ = allocator;

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    const request = "GET /invalid HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var read_buffer: [1024]u8 = undefined;
    var reader_stream = stream.reader(io, &read_buffer);
    var buf: [1024]u8 = undefined;
    const n = try reader_stream.interface.readSliceShort(&buf);
    const response = buf[0..n];

    if (!std.mem.startsWith(u8, response, "HTTP/1.1 404")) {
        std.log.err("Expected HTTP 404 for invalid path, got: {s}", .{response[0..@min(50, n)]});
        return error.Expected404;
    }
}
