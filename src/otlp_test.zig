const std = @import("std");
const http = std.http;

const otlp = @import("otlp.zig");

const ConfigOptions = otlp.ConfigOptions;

const pbcollector_metrics = @import("opentelemetry/proto/collector/metrics/v1.pb.zig");
const pbmetrics = @import("opentelemetry/proto/metrics/v1.pb.zig");

var serverPort = std.atomic.Value(u16).init(4321);
fn getServerPort() u16 {
    return serverPort.fetchAdd(1, .acq_rel);
}

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

    const rm = try allocator.alloc(pbmetrics.ResourceMetrics, 1);
    defer allocator.free(rm);
    const rm0 = pbmetrics.ResourceMetrics{
        .resource = null,
        .scope_metrics = std.ArrayList(pbmetrics.ScopeMetrics).init(allocator),
    };
    defer rm0.deinit();

    rm[0] = rm0;
    const dummy: pbcollector_metrics.ExportMetricsServiceRequest = pbcollector_metrics.ExportMetricsServiceRequest{ .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).fromOwnedSlice(allocator, rm) };

    const result = otlp.Export(allocator, config, otlp.Signal.Data{ .metrics = dummy });
    try std.testing.expectError(otlp.ExportError.NonRetryableStatusCodeInResponse, result);
}

// Type that defines the behavior of the mocked HTTP test server.
const serverBehavior = *const fn (request: *http.Server.Request) anyerror!void;

fn badRequest(request: *http.Server.Request) anyerror!void {
    try request.respond("", .{ .status = .bad_request });
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
            std.debug.print("Error applying mock behavior: {}\n", .{err});
            @panic("HTTP test failure");
        };
    }

    fn port(self: Self) u16 {
        return self.net_server.listen_address.in.getPort();
    }

    fn deinit(self: *Self) void {
        self.net_server.deinit();
        self.allocator.destroy(self);
    }
};
