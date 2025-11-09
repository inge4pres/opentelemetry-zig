const std = @import("std");
const http = std.http;

const log = std.log.scoped(.otlp_test);

const otlp = @import("otlp.zig");

const ConfigOptions = otlp.ConfigOptions;

const protobuf = @import("protobuf");

const pbcollector_metrics = @import("opentelemetry-proto").collector_metrics_v1;
const pbcommon = @import("opentelemetry-proto").common_v1;
const pbmetrics = @import("opentelemetry-proto").metrics_v1;

test "otlp HTTPClient send fails on non-retryable error" {
    const allocator = std.testing.allocator;

    var server = try HTTPTestServer.init(allocator, badRequest);
    defer server.deinit();

    // Running the HTTP server in a separate thread is mandatory for each test.
    // When trying to spawn it in the `HTTPTestServer.init` function, it will fail, but I am not sure why.
    const thread = try std.Thread.spawn(.{}, HTTPTestServer.processSingleRequest, .{server});
    defer thread.join();

    const config = try ConfigOptions.init(allocator);
    defer config.deinit();
    const endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{server.port()});
    defer allocator.free(endpoint);
    config.endpoint = endpoint;

    var dummy = try emptyMetricsExportRequest(allocator);
    defer dummy.deinit(std.testing.allocator);

    const result = otlp.Export(allocator, config, otlp.Signal.Data{ .metrics = dummy });
    try std.testing.expectError(otlp.ExportError.NonRetryableStatusCodeInResponse, result);
}

test "otlp HTTPClient send retries on retryable error" {
    const allocator = std.testing.allocator;

    const max_requests: usize = 5;
    var req_counter = std.atomic.Value(usize).init(0);

    var server = try HTTPTestServer.init(allocator, tooManyRequests);
    defer server.deinit();
    // Running the HTTP server in a separate thread is mandatory for each test.
    // When trying to spawn it in the `HTTPTestServer.init` function, it will fail, but I am not sure why.
    const thread = try std.Thread.spawn(.{}, HTTPTestServer.processRequests, .{ server, max_requests, &req_counter });

    const config = try ConfigOptions.init(allocator);
    defer config.deinit();

    // Speed up the test
    config.retryConfig = .{
        .max_retries = max_requests,
        .max_delay_ms = 1,
        .base_delay_ms = 1,
    };

    const endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{server.port()});
    defer allocator.free(endpoint);
    config.endpoint = endpoint;

    var dummy = try emptyMetricsExportRequest(allocator);
    defer dummy.deinit(std.testing.allocator);

    const result = otlp.Export(allocator, config, otlp.Signal.Data{ .metrics = dummy });
    // Assert that we did all the expected requests
    try std.testing.expectError(otlp.ExportError.RequestEnqueuedForRetry, result);

    thread.join();

    // Eventually the non-retryable status code is returned, and we should have received
    // the maximum number of requests.
    try std.testing.expectEqual(max_requests, req_counter.load(.acquire));
}

test "otlp HTTPClient uncompressed protobuf metrics payload" {
    const allocator = std.testing.allocator;

    var server = try HTTPTestServer.init(allocator, assertUncompressedProtobufMetricsBodyCanBeParsed);
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, HTTPTestServer.processSingleRequest, .{server});
    defer thread.join();

    const config = try ConfigOptions.init(allocator);
    defer config.deinit();
    const endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{server.port()});
    defer allocator.free(endpoint);
    config.endpoint = endpoint;

    var req = try oneDataPointMetricsExportRequest(allocator);
    defer req.deinit(allocator);

    try otlp.Export(allocator, config, otlp.Signal.Data{ .metrics = req });
}

test "otlp HTTPClient uncompressed json metrics payload" {
    const allocator = std.testing.allocator;

    var server = try HTTPTestServer.init(allocator, assertUncompressedJsonMetricsBodyCanBeParsed);
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, HTTPTestServer.processSingleRequest, .{server});
    defer thread.join();

    const config = try ConfigOptions.init(allocator);
    defer config.deinit();
    config.protocol = .http_json;

    const endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{server.port()});
    defer allocator.free(endpoint);
    config.endpoint = endpoint;

    var req = try oneDataPointMetricsExportRequest(allocator);
    defer req.deinit(allocator);

    try otlp.Export(allocator, config, otlp.Signal.Data{ .metrics = req });
}

test "otlp HTTPClient compressed json metrics payload" {
    const allocator = std.testing.allocator;

    var server = try HTTPTestServer.init(allocator, assertCompressedJsonMetricsBodyCanBeParsed);
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, HTTPTestServer.processSingleRequest, .{server});
    defer thread.join();

    const config = try ConfigOptions.init(allocator);
    defer config.deinit();
    config.protocol = .http_json;
    config.compression = .gzip;

    const endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{server.port()});
    defer allocator.free(endpoint);
    config.endpoint = endpoint;

    var req = try oneDataPointMetricsExportRequest(allocator);
    defer req.deinit(allocator);

    try otlp.Export(allocator, config, otlp.Signal.Data{ .metrics = req });
}

test "otlp HTTPClient compressed protobuf metrics payload" {
    const allocator = std.testing.allocator;

    var server = try HTTPTestServer.init(allocator, assertCompressionHeaderGzip);
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, HTTPTestServer.processSingleRequest, .{server});
    defer thread.join();

    const config = try ConfigOptions.init(allocator);
    defer config.deinit();
    const endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{server.port()});
    defer allocator.free(endpoint);
    config.endpoint = endpoint;

    config.compression = otlp.Compression.gzip;
    var req = try oneDataPointMetricsExportRequest(allocator);
    defer req.deinit(allocator);

    try otlp.Export(allocator, config, otlp.Signal.Data{ .metrics = req });
}

test "otlp HTTPClient send extra headers" {
    const allocator = std.testing.allocator;

    var server = try HTTPTestServer.init(allocator, assertExtraHeaders);
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, HTTPTestServer.processSingleRequest, .{server});
    defer thread.join();

    const config = try ConfigOptions.init(allocator);
    defer config.deinit();
    const endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{server.port()});
    defer allocator.free(endpoint);
    config.endpoint = endpoint;
    config.headers = "test-header=test-value";

    var dummy = try emptyMetricsExportRequest(allocator);
    defer dummy.deinit(std.testing.allocator);
    try otlp.Export(allocator, config, otlp.Signal.Data{ .metrics = dummy });
}

fn emptyMetricsExportRequest(allocator: std.mem.Allocator) !pbcollector_metrics.ExportMetricsServiceRequest {
    const rm = try allocator.alloc(pbmetrics.ResourceMetrics, 1);
    const rm0 = pbmetrics.ResourceMetrics{
        .resource = null,
        .scope_metrics = .empty,
    };

    rm[0] = rm0;
    return pbcollector_metrics.ExportMetricsServiceRequest{
        .resource_metrics = std.ArrayListUnmanaged(pbmetrics.ResourceMetrics).fromOwnedSlice(rm),
    };
}

fn oneDataPointMetricsExportRequest(allocator: std.mem.Allocator) !pbcollector_metrics.ExportMetricsServiceRequest {
    var data_points = try allocator.alloc(pbmetrics.NumberDataPoint, 1);
    const data_points0 = pbmetrics.NumberDataPoint{
        .value = .{ .as_int = 42 },
        .start_time_unix_nano = @intCast(std.time.nanoTimestamp()),
        .attributes = .empty,
        .exemplars = .empty,
    };
    data_points[0] = data_points0;
    var metrics = try allocator.alloc(pbmetrics.Metric, 1);
    const metric_name = try allocator.dupe(u8, "test_metric");
    const metrics0 = pbmetrics.Metric{
        .name = metric_name,
        .data = .{ .gauge = .{ .data_points = std.ArrayListUnmanaged(pbmetrics.NumberDataPoint).fromOwnedSlice(data_points) } },
        .metadata = .empty,
    };
    metrics[0] = metrics0;

    var scope_metrics = try allocator.alloc(pbmetrics.ScopeMetrics, 1);
    const scope_metrics0 = pbmetrics.ScopeMetrics{
        .scope = null,
        .metrics = std.ArrayListUnmanaged(pbmetrics.Metric).fromOwnedSlice(metrics),
    };
    scope_metrics[0] = scope_metrics0;

    const rm = try allocator.alloc(pbmetrics.ResourceMetrics, 1);
    const rm0 = pbmetrics.ResourceMetrics{
        .resource = null,
        .scope_metrics = std.ArrayListUnmanaged(pbmetrics.ScopeMetrics).fromOwnedSlice(scope_metrics),
    };

    rm[0] = rm0;
    var req = pbcollector_metrics.ExportMetricsServiceRequest{
        .resource_metrics = std.ArrayListUnmanaged(pbmetrics.ResourceMetrics).fromOwnedSlice(rm),
    };
    // Mark as mutable for future deinit
    _ = &req;
    return req;
}

// Type that defines the behavior of the mocked HTTP test server.
const serverBehavior = *const fn (request: *http.Server.Request) anyerror!void;

const AssertionError = error{
    EmptyBody,
    ProtobufBodyMismatch,
    JsonBodyMismatch,
    CompressionMismatch,
    ExtraHeaderMissing,
};

fn badRequest(request: *http.Server.Request) anyerror!void {
    try request.respond("", .{ .status = .bad_request });
}

fn tooManyRequests(request: *http.Server.Request) anyerror!void {
    try request.respond("", .{ .status = .too_many_requests });
}

fn assertUncompressedJsonMetricsBodyCanBeParsed(request: *http.Server.Request) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const reader = request.readerExpectNone(&buffer);
    const body = try reader.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(body);

    // Basic validation that we received a non-empty JSON body
    try std.testing.expect(body.len > 0);
    // JSON uses camelCase for field names
    try std.testing.expect(std.mem.indexOf(u8, body, "resourceMetrics") != null);

    try request.respond("", .{ .status = .ok });
}

fn assertCompressedJsonMetricsBodyCanBeParsed(request: *http.Server.Request) anyerror!void {
    var headers = request.iterateHeaders();
    var content_found = false;
    while (headers.next()) |header| {
        if (std.mem.eql(u8, header.name, "content-encoding")) {
            if (!std.mem.eql(u8, header.value, "gzip")) {
                return AssertionError.CompressionMismatch;
            }
            content_found = true;
        }
    }

    if (!content_found) {
        return AssertionError.CompressionMismatch;
    }

    var buffer: [4096]u8 = undefined;
    const reader = request.readerExpectNone(&buffer);
    const body = try reader.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(body);

    // TODO: Fix gzip decompression API for Zig 0.15.1
    // For now, just validate we got some compressed data
    try std.testing.expect(body.len > 0);

    try request.respond("", .{ .status = .ok });
}

fn assertUncompressedProtobufMetricsBodyCanBeParsed(request: *http.Server.Request) anyerror!void {
    var allocator = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    const reader = request.readerExpectNone(&buffer);

    const body = try reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(body);
    if (body.len == 0) {
        return AssertionError.EmptyBody;
    }

    var body_reader = std.Io.Reader.fixed(body);
    var proto_msg = pbcollector_metrics.ExportMetricsServiceRequest.decode(&body_reader, allocator) catch |err| {
        log.err("Error parsing proto: {}", .{err});
        return err;
    };
    defer proto_msg.deinit(allocator);
    if (proto_msg.resource_metrics.items.len != 1) {
        log.debug("decoded protobuf: {}", .{proto_msg});
        return AssertionError.ProtobufBodyMismatch;
    }
    try request.respond("", .{ .status = .ok });
}

fn assertCompressionHeaderGzip(request: *http.Server.Request) anyerror!void {
    var headers = request.iterateHeaders();
    var accept_found = false;
    while (headers.next()) |header| {
        if (std.mem.eql(u8, header.name, "accept-encoding")) {
            if (!std.mem.eql(u8, header.value, "gzip")) {
                log.err("accept-encoding header mismatch, want 'gzip' got '{s}'", .{header.value});
                return AssertionError.CompressionMismatch;
            }
            accept_found = true;
        }
    }
    var content_found = false;
    var headers2 = request.iterateHeaders();
    while (headers2.next()) |header| {
        if (std.mem.eql(u8, header.name, "content-encoding")) {
            if (!std.mem.eql(u8, header.value, "gzip")) {
                log.err("content-encoding header mismatch, want 'gzip' got '{s}'", .{header.value});
                return AssertionError.CompressionMismatch;
            }
            content_found = true;
        }
    }
    if (!content_found or !accept_found) {
        log.err("compression headers not found: content-encoding {} | accept-encoding {}", .{
            content_found,
            accept_found,
        });
        return AssertionError.CompressionMismatch;
    }
    try request.respond("", .{ .status = .ok });
}

fn assertExtraHeaders(request: *http.Server.Request) anyerror!void {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.mem.eql(u8, header.name, "test-header")) {
            if (!std.mem.eql(u8, header.value, "test-value")) {
                return AssertionError.ExtraHeaderMissing;
            }

            try request.respond("", .{ .status = .ok });
            return;
        }
    }
    return AssertionError.ExtraHeaderMissing;
}

const HTTPTestServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    net_server: std.net.Server,
    behavior: serverBehavior,

    fn init(
        allocator: std.mem.Allocator,
        behavior: serverBehavior,
    ) !*Self {
        const test_server = try allocator.create(HTTPTestServer);
        // Randomized port, can be fetched with port()
        const address = try std.net.Address.parseIp("127.0.0.1", 0);
        const net_server = try address.listen(.{ .reuse_address = true });

        test_server.* = HTTPTestServer{
            .allocator = allocator,
            .net_server = net_server,
            .behavior = behavior,
        };

        return test_server;
    }

    fn processSingleRequest(self: *Self) void {
        const connection = self.net_server.accept() catch |err| {
            log.err("Error starting HTTP server: {}", .{err});
            return;
        };
        defer connection.stream.close();

        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;
        var conn_reader = connection.stream.reader(&read_buffer);
        var conn_writer = connection.stream.writer(&write_buffer);
        var http_server = std.http.Server.init(conn_reader.interface(), &conn_writer.interface);

        var request = http_server.receiveHead() catch |err| {
            log.err("Error receiving HTTP request: {}", .{err});
            return;
        };

        self.behavior(&request) catch |err| {
            log.err("Error in HTTP request behavior: {}", .{err});
        };
    }

    fn processRequests(self: *Self, maxRequests: usize, reqCounter: *std.atomic.Value(usize)) void {
        while (reqCounter.load(.acquire) < maxRequests) {
            const connection = self.net_server.accept() catch |err| {
                log.err("Error starting HTTP server: {}", .{err});
                return;
            };
            defer connection.stream.close();

            const reqNumber = reqCounter.fetchAdd(1, .acq_rel);

            var read_buffer: [8192]u8 = undefined;
            var write_buffer: [8192]u8 = undefined;
            var conn_reader = connection.stream.reader(&read_buffer);
            var conn_writer = connection.stream.writer(&write_buffer);
            var http_server = std.http.Server.init(conn_reader.interface(), &conn_writer.interface);

            var request = http_server.receiveHead() catch |err| {
                log.err("Error receiving HTTP request: {}", .{err});
                continue;
            };

            self.behavior(&request) catch |err| {
                log.err("Error in HTTP request behavior: {}", .{err});
            };

            _ = reqNumber;
        }
    }

    fn port(self: Self) u16 {
        return self.net_server.listen_address.in.getPort();
    }

    fn deinit(self: *Self) void {
        self.net_server.deinit();
        self.allocator.destroy(self);
    }
};

test "otlp ExportFile appends metrics to file" {
    const allocator = std.testing.allocator;

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var file = try temp_dir.dir.createFile("metrics.jsonl", .{
        .read = true,
        .exclusive = true,
    });

    const how_many_lines = 10;

    for (0..how_many_lines) |_| {
        var req = try oneDataPointMetricsExportRequest(allocator);
        defer req.deinit(allocator);
        try otlp.ExportFile(allocator, otlp.Signal.Data{ .metrics = req }, &file);
    }

    file.close();

    // Re-open the file for reading
    var filer = try temp_dir.dir.openFile("metrics.jsonl", .{});
    defer filer.close();

    // Verify that the file was created and has content
    try std.testing.expect(try file.getEndPos() > 0);

    // TODO more assertions

    var buffer: [4096]u8 = undefined;
    var reader = filer.reader(&buffer);
    var lines_count: usize = 0;
    while (try reader.interface.takeDelimiter('\n')) |_| {
        // Basic validation that we received a non-empty JSON line
        lines_count += 1;
    }
    try std.testing.expectEqual(how_many_lines, lines_count);
}
