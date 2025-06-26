const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const MeterProvider = sdk.MeterProvider;

const otlp = sdk.otlp;
const otlp_stub = @import("otlp-stub");
const pbmetrics = @import("../../src/opentelemetry/proto/collector/metrics/v1.pb.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.detectLeaks()) @panic("leaks detected");

    // number of data points we expect to send
    const how_many = 1000;

    // Set up a stub OTLP server for metrics
    const OnExport = struct {
        pub fn handler(req: *pbmetrics.ExportMetricsServiceRequest) void {
            std.debug.assert(req.resource_metrics.items[0].scope_metrics.items[0].metrics.items[0].data.?.sum.data_points.items.len == how_many);
        }
    };
    var server = try otlp_stub.MetricsStubServer.init(allocator, 4317, OnExport.handler);
    defer server.deinit();

    // Start the server in a background thread
    var stop = std.atomic.Value(bool).init(false);
    var thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *otlp_stub.MetricsStubServer, done: *std.atomic.Value(bool)) !void {
            srv.start(done) catch |e| std.debug.print("Stub server error: {s}\n", .{@errorName(e)});
        }
    }.run, .{ server, &stop });
    defer thread.join();
    defer _ = stop.swap(true, .acq_rel);

    // Configure the OTLP exporter to use the stub server
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    var otel = try setupTelemetry(allocator, config);
    defer otel.otlp_exporter.deinit();
    defer otel.metric_reader.shutdown();

    // Record test metris
    const meter = try otel.meter_provider.getMeter(.{ .name = "otlp-example" });
    var counter = try meter.createCounter(u64, .{ .name = "test_counter" });

    // Since each data points has a different attribute, they'll be stored as indipendent data points in the OTLP payload.
    for (0..how_many) |i| {
        try counter.add(42, .{ "counter", @as(u64, i) });
    }

    try otel.metric_reader.collect();
}

const OTel = struct {
    meter_provider: *sdk.MeterProvider,
    metric_reader: *sdk.MetricReader,
    otlp_exporter: *sdk.OTLPExporter,
};

fn setupTelemetry(allocator: std.mem.Allocator, opts: *otlp.ConfigOptions) !OTel {
    const mp = try sdk.MeterProvider.default();
    errdefer mp.shutdown();

    const me = try sdk.MetricExporter.OTLP(allocator, null, null, opts);
    errdefer me.otlp.deinit();

    const mr = try sdk.MetricReader.init(allocator, me.exporter);
    try mp.addReader(mr);

    return .{
        .meter_provider = mp,
        .metric_reader = mr,
        .otlp_exporter = me.otlp,
    };
}
