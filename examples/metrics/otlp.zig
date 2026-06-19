const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const MeterProvider = metrics_sdk.MeterProvider;

const otlp = sdk.otlp;
const otlp_stub = @import("otlp-stub");
const pbmetrics = @import("opentelemetry-proto").collector_metrics_v1;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // number of data points we expect to send
    const how_many = 10;

    // Set up a stub OTLP server for metrics, and
    const OnExport = struct {
        pub fn handler(req: *pbmetrics.ExportMetricsServiceRequest) void {
            std.debug.assert(req.resource_metrics.items[0].scope_metrics.items[0].metrics.items[0].data.?.sum.data_points.items.len == how_many);
        }
    };
    var server = try otlp_stub.MetricsStubServer.init(allocator, io, 4318, OnExport.handler);
    defer server.deinit();

    // Start the server in a background thread
    var thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *otlp_stub.MetricsStubServer) !void {
            srv.start() catch |e| {
                std.debug.print("Stub server error: {s}\n", .{@errorName(e)});
                @panic("server start failure");
            };
        }
    }.run, .{server});
    defer thread.join();

    // Configure the OTLP exporter to use the stub server
    var config = try sdk.otlp.ConfigOptions.init(allocator, init.environ_map);
    defer config.deinit();

    var otel = try setupTelemetry(allocator, io, config);
    defer otel.meter_provider.shutdown();
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
    meter_provider: *metrics_sdk.MeterProvider,
    metric_reader: *metrics_sdk.MetricReader,
    otlp_exporter: *metrics_sdk.OTLPExporter,
};

fn setupTelemetry(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: *otlp.ConfigOptions,
) !OTel {
    const mp = try metrics_sdk.MeterProvider.init(allocator, io);
    errdefer mp.shutdown();

    const me = try metrics_sdk.MetricExporter.OTLP(allocator, io, null, null, opts);
    errdefer me.otlp.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, io, me.exporter);
    try mp.addReader(mr);

    return .{
        .meter_provider = mp,
        .metric_reader = mr,
        .otlp_exporter = me.otlp,
    };
}
