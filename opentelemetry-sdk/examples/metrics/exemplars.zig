const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const trace_api = sdk.api.trace;
const context = sdk.api.context;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const config = try sdk.config.Configuration.init(allocator, io, init.environ_map);
    defer config.deinit();
    sdk.config.Configuration.set(config);

    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    var traces = try sdk.trace.TracerProvider.init(allocator, io, .{
        .Random = sdk.trace.RandomIDGenerator.init(prng.random()),
    });
    defer traces.deinit();
    const tracer = try traces.getTracer(.{ .name = "exemplar-demo" });

    const provider = try sdk.metrics.MeterProvider.init(allocator, io);
    defer provider.deinit();
    try provider.addView(.{
        .instrument_selector = .{ .name = "requests" },
        .aggregation = .Sum,
        .temporality = .Cumulative,
        .attribute_filter = .{ .include_keys = &.{"route"} },
    });
    const exporter = try sdk.metrics.MetricExporter.InMemory(allocator, io, null, null);
    defer exporter.in_memory.deinit();
    const reader = try sdk.metrics.MetricReader.init(allocator, io, exporter.exporter);
    defer reader.deinit();
    try provider.addReader(reader);
    const meter = try provider.getMeter(.{ .name = "exemplar-demo" });
    const counter = try meter.createCounter(u64, .{ .name = "requests" });
    {
        defer context.cleanup();
        var span = try tracer.startSpan(allocator, "GET /demo", .{ .kind = .Server });
        defer span.deinit();
        var active = try trace_api.insertSpanContext(allocator, span.getContext());
        defer trace_api.freeSerializedSpanContext(allocator, active);
        _ = context.attachContext(active) catch |err| {
            active.deinit();
            return err;
        };
        try counter.add(1, .{ "route", @as([]const u8, "/demo"), "request_id", @as([]const u8, "demo-request") });
        span.end(null);
    }
    // Collection happens after the span and its context have ended.
    try reader.collect();
    const metrics = try exporter.in_memory.fetch(allocator);
    defer {
        for (metrics) |*metric| metric.deinit(allocator);
        allocator.free(metrics);
    }
    for (metrics) |metric| for (metric.data.int) |point| {
        for (point.exemplars) |sample| {
            std.debug.print("request exemplar: {d}, timestamp: {d}\n", .{ sample.value.int, sample.time_ns });
            if (sample.trace_id) |id| {
                var hex: [32]u8 = undefined;
                std.debug.print("trace: {s}\n", .{trace_api.TraceID.init(id).toHex(&hex)});
            }
            for (sample.filtered_attributes) |attribute|
                std.debug.print("{s}: {s}\n", .{ attribute.key, attribute.value.string });
        }
    };
}
