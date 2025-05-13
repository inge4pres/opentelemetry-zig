const std = @import("std");
const http = std.http;

const otlp = @import("otlp.zig");

const ConfigOptions = otlp.ConfigOptions;

const pbcollector_metrics = @import("opentelemetry/proto/collector/metrics/v1.pb.zig");
const pbmetrics = @import("opentelemetry/proto/metrics/v1.pb.zig");

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

// Type that defines the behavior of the mocked HTTP test server.
const serverBehavior = *const fn (request: *http.Server.Request) anyerror!void;

fn badRequest(request: *http.Server.Request) anyerror!void {
    try request.respond("", .{ .status = .bad_request });
}

fn tooManyRequests(request: *http.Server.Request) anyerror!void {
    try request.respond("", .{ .status = .too_many_requests });
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
