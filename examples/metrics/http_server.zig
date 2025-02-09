const std = @import("std");
const http = std.http;
const sdk = @import("opentelemetry-sdk");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const otel = try setupTelemetry(allocator);
    defer {
        otel.metric_reader.shutdown();
        otel.meter_provider.shutdown();
    }

    const ip = "127.0.0.1";
    const port: u16 = 4488;
    var prod_server = MonitoredHTTPServer.init(otel.meter_provider, ip, port) catch |err| {
        std.debug.print("error initializing server: {?}\n", .{err});
        return err;
    };
    // Create a thread that will serve one HTTP request and exit
    const worker = try std.Thread.spawn(.{}, MonitoredHTTPServer.serveRequest, .{&prod_server});
    //TODO move to the end of the function and use worker.join()
    // once the shutdown process is improved in #14
    worker.detach();

    // Send an HTTP request to the server
    var client = http.Client{ .allocator = allocator };
    const uri = try std.Uri.parse("http://127.0.0.1:4488");
    var headers: [4096]u8 = undefined;
    var req = try client.open(.GET, uri, .{ .server_header_buffer = &headers });
    defer req.deinit();
    try req.send();
}

const MonitoredHTTPServer = struct {
    const Self = @This();

    net_server: std.net.Server,

    request_counter: *sdk.Counter(u64),
    response_latency: *sdk.Histogram(f64),

    pub fn init(mp: *sdk.MeterProvider, ip: []const u8, port: u16) !Self {
        const addr = try std.net.Address.parseIp(ip, port);
        const meter = try mp.getMeter(.{ .name = "standard/http.server" });
        std.debug.print("serving HTTP requests\n", .{});
        return Self{
            .net_server = try addr.listen(.{ .reuse_address = true }),
            .request_counter = try meter.createCounter(u64, .{
                .name = "http.server.requests",
                .description = "Total number of HTTP requests received",
            }),
            .response_latency = try meter.createHistogram(f64, .{
                .name = "http.server.request_duration_ms",
                .description = "The duration of HTTP requests, in milliseconds",
                .unit = "ms",
                .histogramOpts = .{ .explicitBuckets = &.{ 0.02, 0.1, 0.5, 2.5 } },
            }),
        };
    }

    pub fn serveRequest(self: *Self) !void {
        const connection = try self.net_server.accept();
        defer connection.stream.close();

        var buf: [8192]u8 = undefined;
        var server = http.Server.init(connection, &buf);

        const start = std.time.milliTimestamp();
        var request = server.receiveHead() catch |err| {
            try self.request_counter.add(1, .{ "error", true, "reason", @errorName(err) });
            return err;
        };
        defer self.response_latency.record(@floatFromInt(std.time.milliTimestamp() - start), .{}) catch unreachable;

        try self.request_counter.add(1, .{ "method", @tagName(request.head.method) }); // success

        // Reply to the request with an empty body and a 200 OK status
        try request.respond("", .{ .status = .ok });
    }
};

const OTel = struct {
    meter_provider: *sdk.MeterProvider,
    metric_reader: *sdk.MetricReader,
};

fn setupTelemetry(allocator: std.mem.Allocator) !OTel {
    const mp = try sdk.MeterProvider.default();
    errdefer mp.shutdown();

    var in_mem = try sdk.InMemoryExporter.init(allocator);
    errdefer in_mem.deinit();

    const exporter = try sdk.MetricExporter.new(allocator, &in_mem.exporter);
    errdefer exporter.shutdown();

    const mr = try sdk.MetricReader.init(allocator, exporter);

    try mp.addReader(mr);

    return .{ .meter_provider = mp, .metric_reader = mr };
}
