//! OTLP/gRPC example — metrics, traces, and logs from one binary.
//!
//! Simulates a small HTTP server handling three requests, exporting all signals
//! over OTLP/gRPC to a local collector.
//!
//! This directory is only built when a real gRPC backend is selected, since the
//! default (`none`) provider fails every export:
//!   zig build sdk-examples -Dgrpc-provider=libgrpc -Dexamples-filter=all_signals
//!   ./zig-out/bin/grpc/all_signals
//!
//! Collector (plain Docker):
//!   docker run --rm -p 4317:4317 otel/opentelemetry-collector
//!
//! The gRPC endpoint defaults to localhost:4317. Override with:
//!   OTEL_EXPORTER_OTLP_ENDPOINT=<host:port> ./zig-out/bin/grpc/all_signals

const std = @import("std");
const clock = @import("clock");
const sdk = @import("opentelemetry-sdk");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const sdk_config = try sdk.config.init(allocator, io, init.environ_map);
    defer sdk_config.deinit();
    sdk.config.set(sdk_config);

    var config = try sdk.otlp.ConfigOptions.init(allocator, init.environ_map);
    defer config.deinit();

    config.protocol = .grpc;
    // Switch to the gRPC port unless the user already set OTEL_EXPORTER_OTLP_ENDPOINT.
    // The default endpoint is not allocated, so it can be replaced.
    if (init.environ_map.get("OTEL_EXPORTER_OTLP_ENDPOINT") == null) {
        config.endpoint = "localhost:4317";
    }

    std.log.info("exporting to {s} via gRPC", .{config.endpoint});

    // ── Metrics ──────────────────────────────────────────────────────────────

    const mp = try sdk.metrics.MeterProvider.init(allocator, io);
    defer mp.deinit();
    const me = try sdk.metrics.MetricExporter.OTLP(allocator, io, null, null, config);
    defer me.otlp.deinit();
    const mr = try sdk.metrics.MetricReader.init(allocator, io, me.exporter);
    defer mr.deinit();
    try mp.addReader(mr);

    const meter = try mp.getMeter(.{ .name = "grpc-example", .version = "1.0.0" });
    var req_count = try meter.createCounter(u64, .{
        .name = "http.server.requests",
        .description = "Total HTTP requests handled",
    });
    var req_duration = try meter.createHistogram(f64, .{
        .name = "http.server.duration",
        .description = "HTTP request duration",
        .unit = "ms",
    });

    // ── Traces ───────────────────────────────────────────────────────────────

    var prng = std.Random.DefaultPrng.init(@intCast(clock.milliTimestamp()));
    const id_generator = sdk.trace.IDGenerator{
        .Random = sdk.trace.RandomIDGenerator.init(prng.random()),
    };
    var tracer_provider = try sdk.trace.TracerProvider.init(allocator, io, id_generator);
    defer tracer_provider.deinit();
    var trace_exporter = try sdk.trace.OTLPExporter.init(allocator, io, config);
    defer trace_exporter.deinit();
    var span_processor = sdk.trace.SimpleProcessor.init(
        allocator,
        io,
        trace_exporter.asSpanExporter(),
    );
    try tracer_provider.addSpanProcessor(span_processor.asSpanProcessor());
    const tracer = try tracer_provider.getTracer(.{ .name = "grpc-example", .version = "1.0.0" });

    // ── Logs ─────────────────────────────────────────────────────────────────

    const resource_attrs = try sdk.Attributes.from(allocator, .{
        "host.name", @as([]const u8, "my-computer"),
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);
    var logs_exporter = try sdk.logs.OTLPExporter.init(allocator, io, config);
    defer logs_exporter.deinit();
    var log_processor = sdk.logs.SimpleLogRecordProcessor.init(
        io,
        logs_exporter.asLogRecordExporter(),
    );
    var logger_provider = try sdk.logs.LoggerProvider.init(allocator, io, resource_attrs);
    defer logger_provider.deinit();
    try logger_provider.addLogRecordProcessor(log_processor.asLogRecordProcessor());
    const logger = try logger_provider.getLogger(sdk.scope.InstrumentationScope{
        .name = "grpc-example",
        .version = "1.0.0",
    });

    // ── Simulate request handling ─────────────────────────────────────────────

    logger.emit(.info, "server started", .{});

    const requests = [_]struct {
        method: []const u8,
        path: []const u8,
        latency_ms: f64,
    }{
        .{ .method = "GET", .path = "/api/users", .latency_ms = 12.4 },
        .{ .method = "POST", .path = "/api/orders", .latency_ms = 87.2 },
        .{ .method = "GET", .path = "/api/items", .latency_ms = 5.1 },
    };

    for (requests) |req| {
        var span = try tracer.startSpan(allocator, req.path, .{ .kind = .Server });
        defer span.deinit();
        try span.setAttribute("http.method", .{ .string = req.method });
        try span.setAttribute("http.route", .{ .string = req.path });
        try span.setAttribute("example.source", .{ .string = "grpc-all-signals" });

        logger.emitStructured(.info, .{
            .method = req.method,
            .path = req.path,
            .duration = req.latency_ms,
        }, .{ .span_context = span.span_context });

        clock.sleep(@as(u64, @intFromFloat(req.latency_ms * std.time.ns_per_ms)));

        try req_count.add(1, .{
            "http.method", req.method,
            "http.route",  req.path,
        });
        try req_duration.record(req.latency_ms, .{
            "http.method", req.method,
            "http.route",  req.path,
        });

        span.setStatus(sdk.api.trace.Status.ok());
        span.end(null);

        var trace_buf: [32]u8 = undefined;
        var span_buf: [16]u8 = undefined;
        std.log.info("{s} {s} — {d:.1} ms  trace={s} span={s}", .{
            req.method,
            req.path,
            req.latency_ms,
            span.span_context.trace_id.toHex(&trace_buf),
            span.span_context.span_id.toHex(&span_buf),
        });
    }

    logger.emitStructured(.warn, .{
        .path = @as([]const u8, "/api/orders"),
        .duration = @as(f64, 87.2),
        .threshold = @as(f64, 50.0),
    }, .{});
    logger.emit(.info, "server shutting down", .{});

    // Flush all three pipelines. The simple processors log and swallow their
    // export failures; do the same here so a missing collector ends the
    // example with a hint rather than a stack trace.
    mr.collect() catch |err| std.log.err(
        "metrics flush failed: {t} — is a collector listening on {s}?",
        .{ err, config.endpoint },
    );
    logger_provider.shutdown() catch |err| std.log.err("logs flush failed: {t}", .{err});

    std.log.info("done", .{});
}
