//! Integration test for OTLP/gRPC export of metrics, traces and logs.
//!
//! Requires the SDK to be built with `-Dgrpc-provider=libgrpc`. With the
//! default (`none`) provider this binary self-skips: it prints a warning and
//! exits 0, so it can sit in the same CI matrix as the HTTP integration tests
//! without forcing them to know about the gRPC backend.
//!
//! Run with:
//!   zig build sdk-run-integration -Dgrpc-provider=libgrpc -Dintegration-filter=grpc

const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const trace_sdk = sdk.trace;
const trace_api = sdk.api.trace;
const logs_sdk = sdk.logs;
const common = @import("common");

const scope_name = "integration-test-grpc";
const routes = [_][]const u8{ "/api/users", "/api/orders", "/api/items" };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    if (common.grpc_provider == .none) {
        std.debug.print(
            "⚠ Skipping logs_grpc: SDK built with -Dgrpc-provider=none. " ++
                "Re-run with -Dgrpc-provider=libgrpc to exercise the gRPC transport.\n",
            .{},
        );
        return;
    }

    var ctx = try common.setupTestContext(allocator, io, "grpc");
    defer common.cleanupTestContext(&ctx, io);

    // One configuration shared by all signals, as in examples/grpc/all_signals.zig.
    const config = try sdk.otlp.ConfigOptions.init(allocator, init.environ_map);
    defer config.deinit();

    // Talk to the collector's gRPC port, in plaintext. We deliberately leave
    // `config.insecure` unset so the default credential-selection logic
    // applies: a localhost endpoint with no TLS material falls back to
    // LOCAL_TCP, which is plaintext but loopback-only — the exact path most
    // dev setups will hit.
    config.protocol = .grpc;
    config.endpoint = "localhost:" ++ common.COLLECTOR_GRPC_PORT;
    // Not checked by the collector: this only ensures headers don't break the export,
    // gRPC refusing uppercase metadata keys unless the transport lowercases them
    config.headers = "X-Integration-Test=grpc";

    std.debug.print("Running metrics gRPC integration test...\n", .{});
    try testMetricsOverGrpc(allocator, io, config, ctx.tmp_dir);
    std.debug.print("✓ Metrics gRPC test passed\n\n", .{});

    std.debug.print("Running traces gRPC integration test...\n", .{});
    try testTracesOverGrpc(allocator, io, config, ctx.tmp_dir);
    std.debug.print("✓ Traces gRPC test passed\n\n", .{});

    std.debug.print("Running logs gRPC integration test...\n", .{});
    try testLogsOverGrpc(allocator, io, config, ctx.tmp_dir);
    std.debug.print("✓ Logs gRPC test passed\n\n", .{});

    // The collector decompresses gRPC messages whatever the compression, so this only
    // checks that a compressed message is accepted, not that the exporter compressed it.
    std.debug.print("Running gzip-compressed logs gRPC integration test...\n", .{});
    config.compression = .gzip;
    try testLogsOverGrpcWithCompression(allocator, io, config, ctx.tmp_dir);
    std.debug.print("✓ Compressed logs gRPC test passed\n\n", .{});
}

fn testMetricsOverGrpc(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *sdk.otlp.ConfigOptions,
    tmp_dir: std.Io.Dir,
) !void {
    const mp = try metrics_sdk.MeterProvider.init(allocator, io);
    defer mp.deinit();

    const me = try metrics_sdk.MetricExporter.OTLP(allocator, io, null, null, config);
    defer me.otlp.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, io, me.exporter);
    // mr.deinit() also shuts down me.exporter (the MetricExporter wrapper).
    defer mr.deinit();
    try mp.addReader(mr);

    const meter = try mp.getMeter(.{ .name = scope_name, .version = "1.0.0" });
    var req_count = try meter.createCounter(u64, .{
        .name = "http.server.requests",
        .description = "Total HTTP requests handled",
    });
    var req_duration = try meter.createHistogram(f64, .{
        .name = "http.server.duration",
        .description = "HTTP request duration",
        .unit = "ms",
    });

    for (routes, 0..) |route, i| {
        try req_count.add(1, .{ "http.route", route });
        try req_duration.record(@floatFromInt(10 * (i + 1)), .{ "http.route", route });
    }

    try mr.collect();

    std.Io.sleep(io, .fromNanoseconds(1 * std.time.ns_per_s), .awake) catch {};

    std.debug.print("  Sent {d} requests worth of metrics over gRPC\n", .{routes.len});
    std.debug.print("  Waiting for metrics JSON file...\n", .{});

    const json_content = common.waitForFileContent(allocator, io, tmp_dir, "metrics.json", "http.server.requests", 15) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            const stale_content = common.readJsonFile(allocator, io, tmp_dir, "metrics.json") catch {
                std.debug.print("  ERROR: Could not read metrics.json\n", .{});
                return error.MetricsNotReceivedByCollector;
            };
            defer allocator.free(stale_content);
            std.debug.print("  ERROR: gRPC metrics JSON doesn't contain expected data\n", .{});
            std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{stale_content[0..@min(stale_content.len, 500)]});
            return error.MetricsNotReceivedByCollector;
        }
        return err;
    };
    defer allocator.free(json_content);

    const has_counter = std.mem.indexOf(u8, json_content, "http.server.requests") != null;
    const has_histogram = std.mem.indexOf(u8, json_content, "http.server.duration") != null;
    const has_resource_metrics = std.mem.indexOf(u8, json_content, "resourceMetrics") != null or
        std.mem.indexOf(u8, json_content, "resource_metrics") != null;
    const has_scope_name = std.mem.indexOf(u8, json_content, scope_name) != null;

    if (!has_counter or !has_histogram or !has_resource_metrics or !has_scope_name) {
        std.debug.print("  ERROR: gRPC metrics JSON doesn't contain expected data\n", .{});
        std.debug.print("  has_counter={}, has_histogram={}, has_resource_metrics={}, has_scope_name={}\n", .{
            has_counter, has_histogram, has_resource_metrics, has_scope_name,
        });
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.MetricsNotReceivedByCollector;
    }

    std.debug.print("  ✓ gRPC metrics JSON validated - found counter and histogram\n", .{});
}

fn testTracesOverGrpc(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *sdk.otlp.ConfigOptions,
    tmp_dir: std.Io.Dir,
) !void {
    var prng = std.Random.DefaultPrng.init(@bitCast(std.Io.Clock.real.now(io).toMilliseconds()));
    const id_generator = trace_sdk.IDGenerator{
        .Random = trace_sdk.RandomIDGenerator.init(prng.random()),
    };

    var tracer_provider = try trace_sdk.TracerProvider.init(allocator, io, id_generator);
    defer tracer_provider.deinit();

    var otlp_exporter = try trace_sdk.OTLPExporter.init(allocator, io, config);
    defer otlp_exporter.deinit();

    var simple_processor = trace_sdk.SimpleProcessor.init(
        allocator,
        io,
        otlp_exporter.asSpanExporter(),
    );
    try tracer_provider.addSpanProcessor(simple_processor.asSpanProcessor());

    const tracer = try tracer_provider.getTracer(.{ .name = scope_name, .version = "1.0.0" });

    for (routes) |route| {
        var span = try tracer.startSpan(allocator, route, .{ .kind = .Server });
        defer span.deinit();
        try span.setAttribute("http.route", .{ .string = route });
        try span.setAttribute("transport", .{ .string = "grpc" });

        span.setStatus(trace_api.Status.ok());
        span.end(null);
    }

    std.Io.sleep(io, .fromNanoseconds(1 * std.time.ns_per_s), .awake) catch {};

    std.debug.print("  Sent {d} spans over gRPC\n", .{routes.len});
    std.debug.print("  Waiting for traces JSON file...\n", .{});

    const json_content = common.waitForFileContent(allocator, io, tmp_dir, "traces.json", "/api/orders", 15) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            const stale_content = common.readJsonFile(allocator, io, tmp_dir, "traces.json") catch {
                std.debug.print("  ERROR: Could not read traces.json\n", .{});
                return error.TracesNotReceivedByCollector;
            };
            defer allocator.free(stale_content);
            std.debug.print("  ERROR: gRPC traces JSON doesn't contain expected data\n", .{});
            std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{stale_content[0..@min(stale_content.len, 500)]});
            return error.TracesNotReceivedByCollector;
        }
        return err;
    };
    defer allocator.free(json_content);

    const has_span = std.mem.indexOf(u8, json_content, "/api/orders") != null;
    const has_resource_spans = std.mem.indexOf(u8, json_content, "resourceSpans") != null or
        std.mem.indexOf(u8, json_content, "resource_spans") != null;
    const has_scope_name = std.mem.indexOf(u8, json_content, scope_name) != null;

    if (!has_span or !has_resource_spans or !has_scope_name) {
        std.debug.print("  ERROR: gRPC traces JSON doesn't contain expected data\n", .{});
        std.debug.print("  has_span={}, has_resource_spans={}, has_scope_name={}\n", .{
            has_span, has_resource_spans, has_scope_name,
        });
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.TracesNotReceivedByCollector;
    }

    std.debug.print("  ✓ gRPC traces JSON validated - found expected spans\n", .{});
}

fn testLogsOverGrpc(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *sdk.otlp.ConfigOptions,
    tmp_dir: std.Io.Dir,
) !void {
    var otlp_exporter = try logs_sdk.OTLPExporter.init(allocator, io, config);
    defer otlp_exporter.deinit();
    const exporter = otlp_exporter.asLogRecordExporter();

    var simple_processor = logs_sdk.SimpleLogRecordProcessor.init(io, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    const service_name: []const u8 = "integration-test-grpc";
    const resource_attrs = try sdk.Attributes.from(allocator, .{
        "service.name", service_name,
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);

    var provider = try logs_sdk.LoggerProvider.init(allocator, io, resource_attrs);
    defer provider.deinit();

    try provider.addLogRecordProcessor(processor);

    const logger = try provider.getLogger(.{ .name = scope_name, .version = "1.0.0" });

    const num_logs = 5;
    logger.emit(.trace, "gRPC trace log", .{ .severity_text = "TRACE" });
    logger.emit(.debug, "gRPC debug log", .{});
    logger.emit(.info, "gRPC info log", .{});
    logger.emit(.warn, "gRPC warning log", .{ .severity_text = "WARNING" });
    logger.emit(.err, "gRPC error log", .{});

    const attrs = [_]sdk.attributes.Attribute{
        .{ .key = "transport", .value = .{ .string = "grpc" } },
        .{ .key = "test.iteration", .value = .{ .int = 1 } },
    };
    logger.emit(.info, "gRPC log with attributes", .{ .attributes = &attrs });

    try provider.shutdown();

    std.Io.sleep(io, .fromNanoseconds(1 * std.time.ns_per_s), .awake) catch {};

    std.debug.print("  Sent {d} log records over gRPC\n", .{num_logs + 1});
    std.debug.print("  Waiting for logs JSON file...\n", .{});

    const json_content = common.waitForFileContent(allocator, io, tmp_dir, "logs.json", "gRPC info log", 15) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            const stale_content = common.readJsonFile(allocator, io, tmp_dir, "logs.json") catch {
                std.debug.print("  ERROR: Could not read logs.json\n", .{});
                return error.LogsNotReceivedByCollector;
            };
            defer allocator.free(stale_content);
            std.debug.print("  ERROR: gRPC logs JSON doesn't contain expected data\n", .{});
            std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{stale_content[0..@min(stale_content.len, 500)]});
            return error.LogsNotReceivedByCollector;
        }
        return err;
    };
    defer allocator.free(json_content);

    const has_grpc_log = std.mem.indexOf(u8, json_content, "gRPC info log") != null;
    const has_resource_logs = std.mem.indexOf(u8, json_content, "resourceLogs") != null or
        std.mem.indexOf(u8, json_content, "resource_logs") != null;
    const has_service_name = std.mem.indexOf(u8, json_content, service_name) != null;
    const has_transport_attr = std.mem.indexOf(u8, json_content, "grpc") != null;

    if (!has_grpc_log or !has_resource_logs or !has_service_name) {
        std.debug.print("  ERROR: gRPC logs JSON doesn't contain expected data\n", .{});
        std.debug.print("  has_grpc_log={}, has_resource_logs={}, has_service_name={}\n", .{
            has_grpc_log, has_resource_logs, has_service_name,
        });
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.LogsNotReceivedByCollector;
    }

    std.debug.print("  ✓ gRPC logs JSON validated - found expected log records\n", .{});
    if (has_transport_attr) {
        std.debug.print("  ✓ Transport attribute 'grpc' present\n", .{});
    }
}

fn testLogsOverGrpcWithCompression(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *sdk.otlp.ConfigOptions,
    tmp_dir: std.Io.Dir,
) !void {
    var otlp_exporter = try logs_sdk.OTLPExporter.init(allocator, io, config);
    defer otlp_exporter.deinit();

    var simple_processor = logs_sdk.SimpleLogRecordProcessor.init(io, otlp_exporter.asLogRecordExporter());

    var provider = try logs_sdk.LoggerProvider.init(allocator, io, null);
    defer provider.deinit();

    try provider.addLogRecordProcessor(simple_processor.asLogRecordProcessor());

    const logger = try provider.getLogger(.{ .name = scope_name, .version = "1.0.0" });
    // gRPC sends a message uncompressed unless compressing makes it smaller, which a
    // short record with varied content may not: use a body that gzip shrinks a lot.
    const prefix = "gRPC gzip log ";
    var body: [256]u8 = undefined;
    @memset(&body, 'a');
    @memcpy(body[0..prefix.len], prefix);
    logger.emit(.info, &body, .{});

    try provider.shutdown();

    std.Io.sleep(io, .fromNanoseconds(1 * std.time.ns_per_s), .awake) catch {};

    std.debug.print("  Sent a gzip-compressed log record over gRPC\n", .{});
    std.debug.print("  Waiting for logs JSON file...\n", .{});

    const json_content = common.waitForFileContent(allocator, io, tmp_dir, "logs.json", "gRPC gzip log", 15) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            std.debug.print("  ERROR: gRPC logs JSON doesn't contain the compressed log record\n", .{});
            return error.CompressedLogsNotReceivedByCollector;
        }
        return err;
    };
    defer allocator.free(json_content);

    std.debug.print("  ✓ gRPC compressed logs JSON validated - found the log record\n", .{});
}
