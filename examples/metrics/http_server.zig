const std = @import("std");
const clock = @import("clock");
const http = std.http;
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const view = metrics_sdk.View;
const Kind = metrics_sdk.Kind;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const otel = try setupTelemetry(allocator, io);
    defer {
        otel.metric_reader.shutdown();
        otel.meter_provider.shutdown();
        otel.in_memory_exporter.deinit();
    }

    const ip = "127.0.0.1";
    const port: u16 = 4488;
    var prod_server = MonitoredHTTPServer.init(otel.meter_provider, io, ip, port) catch |err| {
        std.debug.print("error initializing server: {}\n", .{err});
        return err;
    };
    // Create a thread that will serve one HTTP request and exit
    const worker = try std.Thread.spawn(.{}, MonitoredHTTPServer.serveRequest, .{&prod_server});

    // Send an HTTP request to the server
    var client = http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    const uri = try std.Uri.parse("http://127.0.0.1:4488");
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();

    worker.join();

    // Manually do the actions that would be done by the SDK
    try otel.metric_reader.collect();
    const metrics = try otel.in_memory_exporter.fetch(allocator);
    defer {
        for (metrics) |*m| {
            m.deinit(allocator);
        }
        allocator.free(metrics);
    }

    std.debug.assert(metrics.len == 2);
    std.debug.assert(metrics[0].instrumentKind == .Counter);
}

const MonitoredHTTPServer = struct {
    const Self = @This();

    net_server: std.Io.net.Server,
    io: std.Io,

    request_counter: *metrics_sdk.Counter(u64),
    response_latency: *metrics_sdk.Histogram(f64),

    pub fn init(mp: *metrics_sdk.MeterProvider, io: std.Io, ip: []const u8, port: u16) !Self {
        const address = try std.Io.net.IpAddress.parse(ip, port);
        const meter = try mp.getMeter(.{ .name = "standard/http.server" });
        return Self{
            .net_server = try address.listen(io, .{ .reuse_address = true }),
            .io = io,
            .request_counter = try meter.createCounter(u64, .{
                .name = "http.server.requests",
                .description = "Total number of HTTP requests received",
            }),
            .response_latency = try meter.createHistogram(f64, .{
                .name = "http.server.request_duration_ms",
                .description = "The duration of HTTP requests, in milliseconds",
                .unit = "ms",
            }),
        };
    }

    pub fn serveRequest(self: *Self) !void {
        var stream = try self.net_server.accept(self.io);
        defer stream.close(self.io);

        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;
        var conn_reader = stream.reader(self.io, &read_buffer);
        var conn_writer = stream.writer(self.io, &write_buffer);
        var server = http.Server.init(&conn_reader.interface, &conn_writer.interface);

        const start = clock.milliTimestamp();
        defer self.response_latency.record(@floatFromInt(clock.milliTimestamp() - start), .{}) catch unreachable;

        var request = server.receiveHead() catch |err| {
            try self.request_counter.add(1, .{ "error", true, "reason", @errorName(err) });
            return err;
        };

        try self.request_counter.add(1, .{ "method", @tagName(request.head.method) }); // success

        // Reply to the request with an empty body and a 200 OK status
        try request.respond("", .{ .status = .ok });
    }
};

const OTel = struct {
    meter_provider: *metrics_sdk.MeterProvider,
    metric_reader: *metrics_sdk.MetricReader,
    in_memory_exporter: *metrics_sdk.InMemoryExporter,
};

fn setupTelemetry(allocator: std.mem.Allocator, io: std.Io) !OTel {
    const mp = try metrics_sdk.MeterProvider.init(allocator, io);
    errdefer mp.shutdown();

    // Create a view for histogram instruments with explicit bucket aggregation
    const http_latency_view = view.View{
        .instrument_selector = .{ .kind = .Histogram },
        .aggregation = .{ .ExplicitBucketHistogram = .{
            .buckets = &.{ 0.02, 0.1, 0.5, 2.5 },
        } },
        .temporality = .Cumulative,
    };

    // Register the view with the meter provider
    try mp.addView(http_latency_view);

    const me = try metrics_sdk.MetricExporter.InMemory(allocator, io, null, null);
    var in_mem = me.in_memory;
    errdefer in_mem.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, io, me.exporter);
    try mp.addReader(mr);

    return .{
        .meter_provider = mp,
        .metric_reader = mr,
        .in_memory_exporter = in_mem,
    };
}
