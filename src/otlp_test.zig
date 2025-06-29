const std = @import("std");
const http = std.http;

const otlp = @import("otlp.zig");

const ConfigOptions = otlp.ConfigOptions;

const protobuf = @import("protobuf");

const pbcollector_metrics = @import("opentelemetry-proto").collector_metrics;
const pbcommon = @import("opentelemetry-proto").common;
const pbmetrics = @import("opentelemetry-proto").metrics;

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

    const dummy = try emptyMetricsExportRequest(allocator);
    defer dummy.deinit();

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

    const dummy = try emptyMetricsExportRequest(allocator);
    defer dummy.deinit();

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

    const req = try oneDataPointMetricsExportRequest(allocator);
    defer req.deinit();

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

    const req = try oneDataPointMetricsExportRequest(allocator);
    defer req.deinit();

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

    const req = try oneDataPointMetricsExportRequest(allocator);
    defer req.deinit();

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
    const req = try oneDataPointMetricsExportRequest(allocator);
    defer req.deinit();

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

    const dummy = try emptyMetricsExportRequest(allocator);
    defer dummy.deinit();
    try otlp.Export(allocator, config, otlp.Signal.Data{ .metrics = dummy });
}

fn emptyMetricsExportRequest(allocator: std.mem.Allocator) !pbcollector_metrics.ExportMetricsServiceRequest {
    const rm = try allocator.alloc(pbmetrics.ResourceMetrics, 1);
    const rm0 = pbmetrics.ResourceMetrics{
        .resource = null,
        .scope_metrics = std.ArrayList(pbmetrics.ScopeMetrics).init(allocator),
    };

    rm[0] = rm0;
    const dummy = pbcollector_metrics.ExportMetricsServiceRequest{
        .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).fromOwnedSlice(allocator, rm),
    };
    return dummy;
}

fn oneDataPointMetricsExportRequest(allocator: std.mem.Allocator) !pbcollector_metrics.ExportMetricsServiceRequest {
    var data_points = try allocator.alloc(pbmetrics.NumberDataPoint, 1);
    const data_points0 = pbmetrics.NumberDataPoint{
        .value = .{ .as_int = 42 },
        .start_time_unix_nano = @intCast(std.time.nanoTimestamp()),
        .attributes = std.ArrayList(pbcommon.KeyValue).init(allocator),
        .exemplars = std.ArrayList(pbmetrics.Exemplar).init(allocator),
    };
    data_points[0] = data_points0;
    var metrics = try allocator.alloc(pbmetrics.Metric, 1);
    const metrics0 = pbmetrics.Metric{
        .name = protobuf.ManagedString.managed("test_metric"),
        .data = .{ .gauge = .{ .data_points = std.ArrayList(pbmetrics.NumberDataPoint).fromOwnedSlice(allocator, data_points) } },
        .metadata = std.ArrayList(pbcommon.KeyValue).init(allocator),
    };
    metrics[0] = metrics0;

    var scope_metrics = try allocator.alloc(pbmetrics.ScopeMetrics, 1);
    const scope_metrics0 = pbmetrics.ScopeMetrics{
        .scope = null,
        .metrics = std.ArrayList(pbmetrics.Metric).fromOwnedSlice(allocator, metrics),
    };
    scope_metrics[0] = scope_metrics0;

    const rm = try allocator.alloc(pbmetrics.ResourceMetrics, 1);
    const rm0 = pbmetrics.ResourceMetrics{
        .resource = null,
        .scope_metrics = std.ArrayList(pbmetrics.ScopeMetrics).fromOwnedSlice(allocator, scope_metrics),
    };

    rm[0] = rm0;
    const req = pbcollector_metrics.ExportMetricsServiceRequest{
        .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).fromOwnedSlice(allocator, rm),
    };
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
    const reader = try request.reader();
    const body = try reader.readAllAlloc(std.testing.allocator, 8192);
    defer std.testing.allocator.free(body);

    const parsed = try pbcollector_metrics.ExportMetricsServiceRequest.json_decode(body, .{}, std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expectEqual(1, parsed.value.resource_metrics.items.len);
    try std.testing.expectEqual(1, parsed.value.resource_metrics.items[0].scope_metrics.items.len);

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

    const reader = try request.reader();
    const body = try reader.readAllAlloc(std.testing.allocator, 8192);
    defer std.testing.allocator.free(body);

    var json_body = std.ArrayList(u8).init(std.testing.allocator);
    defer json_body.deinit();

    var fixed_buffer_stream = std.io.fixedBufferStream(body);
    const compressed_reader = fixed_buffer_stream.reader();
    try std.compress.gzip.decompress(compressed_reader, json_body.writer());

    const parsed = try pbcollector_metrics.ExportMetricsServiceRequest.json_decode(json_body.items, .{}, std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expectEqual(1, parsed.value.resource_metrics.items.len);
    try std.testing.expectEqual(1, parsed.value.resource_metrics.items[0].scope_metrics.items.len);

    try request.respond("", .{ .status = .ok });
}

fn assertUncompressedProtobufMetricsBodyCanBeParsed(request: *http.Server.Request) anyerror!void {
    var allocator = std.testing.allocator;
    const reader = try request.reader();

    const body = try reader.readAllAlloc(allocator, 8192);
    defer allocator.free(body);
    if (body.len == 0) {
        return AssertionError.EmptyBody;
    }

    const proto_msg = pbcollector_metrics.ExportMetricsServiceRequest.decode(body, allocator) catch |err| {
        std.debug.print("Error parsing proto: {}\n", .{err});
        return err;
    };
    defer proto_msg.deinit();
    if (proto_msg.resource_metrics.items.len != 1) {
        std.debug.print("otlp HTTP test - decoded protobuf: {}\n", .{proto_msg});
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
                std.debug.print("otlp HTTP test accept-encoding header mismatch, want 'gzip' got '{s}'\n", .{header.value});
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
                std.debug.print("otlp HTTP test content-encoding header mismatch, want 'gzip' got '{s}'\n", .{header.value});
                return AssertionError.CompressionMismatch;
            }
            content_found = true;
        }
    }
    if (!content_found or !accept_found) {
        std.debug.print("otlp HTTP test compression headers not found: content-encoding {} | accept-encoding {}\n", .{
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
            std.debug.print("Error starting HTTP server: {}\n", .{err});
            return;
        };
        defer connection.stream.close();

        var buf: [8192]u8 = undefined;
        var server = http.Server.init(connection, &buf);

        var request = server.receiveHead() catch |err| {
            std.debug.print("Error receiving request: {}\n", .{err});
            return;
        };

        self.behavior(&request) catch |err| {
            std.debug.print("OTLP HTTP test error applying mock behavior: {}\n", .{err});
            @panic("HTTP test failure");
        };
    }

    fn processRequests(self: *Self, maxRequests: usize, reqCounter: *std.atomic.Value(usize)) void {
        while (reqCounter.load(.acquire) < maxRequests) {
            const connection = self.net_server.accept() catch |err| {
                std.debug.print("Error starting HTTP server: {}\n", .{err});
                return;
            };
            defer connection.stream.close();

            const reqNumber = reqCounter.fetchAdd(1, .acq_rel);

            var buf: [8192]u8 = undefined;
            var server = http.Server.init(connection, &buf);

            var request = server.receiveHead() catch |err| {
                std.debug.print("OTLP HTTP test error receiving retried request: {}\n", .{err});
                return;
            };
            if (reqNumber < maxRequests - 1) {
                self.behavior(&request) catch |err| {
                    std.debug.print("OTLP HTTP test error applying mock behavior: {}\n", .{err});
                    return;
                };
            } else {
                // Reply with a success so we stop the client from sending more requests
                request.respond(
                    "",
                    .{ .status = .ok },
                ) catch |err| {
                    std.debug.print("OTLP HTTP test error responding to request: {}\n", .{err});
                    return;
                };
                return;
            }
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
