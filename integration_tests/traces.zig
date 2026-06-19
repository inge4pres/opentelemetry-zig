const std = @import("std");
const clock = @import("clock");
const sdk = @import("opentelemetry-sdk");
const trace_sdk = sdk.trace;
const trace_api = sdk.api.trace;
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var ctx = try common.setupTestContext(allocator, io, "traces");
    defer common.cleanupTestContext(&ctx, io);

    std.debug.print("Running traces integration test...\n", .{});
    try testTraces(allocator, io, init.environ_map, ctx.tmp_dir);
    std.debug.print("✓ Traces test passed\n\n", .{});

    std.debug.print("Running traces compression test...\n", .{});
    try testTracesWithCompression(allocator, io, init.environ_map, ctx.tmp_dir);
    std.debug.print("✓ Traces compression test passed\n\n", .{});
}

fn testTraces(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    tmp_dir: std.Io.Dir,
) !void {
    var config = try sdk.otlp.ConfigOptions.init(allocator, env_map);
    defer config.deinit();

    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;

    var prng = std.Random.DefaultPrng.init(@intCast(clock.milliTimestamp()));
    const id_generator = trace_sdk.IDGenerator{
        .Random = trace_sdk.RandomIDGenerator.init(prng.random()),
    };

    var tracer_provider = try trace_sdk.TracerProvider.init(allocator, io, id_generator);
    defer tracer_provider.shutdown();

    var otlp_exporter = try trace_sdk.OTLPExporter.init(allocator, io, config);
    defer otlp_exporter.deinit();

    var simple_processor = trace_sdk.SimpleProcessor.init(
        allocator,
        io,
        otlp_exporter.asSpanExporter(),
    );

    const span_processor = simple_processor.asSpanProcessor();
    try tracer_provider.addSpanProcessor(span_processor);

    const tracer = try tracer_provider.getTracer(.{
        .name = "integration-test",
        .version = "1.0.0",
    });

    const num_spans = 3;
    for (0..num_spans) |i| {
        const span_name = try std.fmt.allocPrint(allocator, "test-span-{d}", .{i});
        defer allocator.free(span_name);

        const span_attributes = try sdk.Attributes.from(allocator, .{
            "span.index", @as(i64, @intCast(i)),
            "test.name",  @as([]const u8, "integration-test"),
        });
        defer if (span_attributes) |attrs| allocator.free(attrs);

        var span = try tracer.startSpan(allocator, span_name, .{
            .kind = .Internal,
            .attributes = span_attributes,
        });
        defer span.deinit();

        clock.sleep(10 * std.time.ns_per_ms);

        span.setStatus(trace_api.Status.ok());
        tracer.endSpan(&span);
    }

    std.debug.print("  Waiting for collector to process and write traces...\n", .{});
    clock.sleep(2 * std.time.ns_per_s);

    std.debug.print("  Successfully sent {d} trace spans\n", .{num_spans});
    std.debug.print("  Waiting for traces JSON file...\n", .{});

    try common.waitForFile(io, tmp_dir, "traces.json", 20);

    const json_content = try common.readJsonFile(allocator, io, tmp_dir, "traces.json");
    defer allocator.free(json_content);

    const has_test_span = std.mem.indexOf(u8, json_content, "test-span") != null;
    const has_resource_spans = std.mem.indexOf(u8, json_content, "resourceSpans") != null or
        std.mem.indexOf(u8, json_content, "resource_spans") != null;
    const has_integration_test = std.mem.indexOf(u8, json_content, "integration-test") != null;

    if (!has_test_span or !has_resource_spans or !has_integration_test) {
        std.debug.print("  ERROR: Traces JSON doesn't contain expected data\n", .{});
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.TracesNotReceivedByCollector;
    }

    std.debug.print("  ✓ Traces JSON validated - found {d} test spans\n", .{num_spans});
}

fn testTracesWithCompression(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    tmp_dir: std.Io.Dir,
) !void {
    var config = try sdk.otlp.ConfigOptions.init(allocator, env_map);
    defer config.deinit();

    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;
    config.compression = .gzip;

    var prng = std.Random.DefaultPrng.init(@intCast(clock.milliTimestamp()));
    const id_generator = trace_sdk.IDGenerator{
        .Random = trace_sdk.RandomIDGenerator.init(prng.random()),
    };

    var tracer_provider = try trace_sdk.TracerProvider.init(allocator, io, id_generator);
    defer tracer_provider.shutdown();

    var otlp_exporter = try trace_sdk.OTLPExporter.init(allocator, io, config);
    defer otlp_exporter.deinit();

    var simple_processor = trace_sdk.SimpleProcessor.init(
        allocator,
        io,
        otlp_exporter.asSpanExporter(),
    );

    const span_processor = simple_processor.asSpanProcessor();
    try tracer_provider.addSpanProcessor(span_processor);

    const tracer = try tracer_provider.getTracer(.{
        .name = "integration-test-compression",
        .version = "1.0.0",
    });

    const num_spans = 3;
    for (0..num_spans) |i| {
        const span_name = try std.fmt.allocPrint(allocator, "test-span-compressed-{d}", .{i});
        defer allocator.free(span_name);

        const span_attributes = try sdk.Attributes.from(allocator, .{
            "span.index",  @as(i64, @intCast(i)),
            "test.name",   @as([]const u8, "integration-test-compression"),
            "compression", @as([]const u8, "gzip"),
        });
        defer if (span_attributes) |attrs| allocator.free(attrs);

        var span = try tracer.startSpan(allocator, span_name, .{
            .kind = .Internal,
            .attributes = span_attributes,
        });
        defer span.deinit();

        clock.sleep(10 * std.time.ns_per_ms);

        span.setStatus(trace_api.Status.ok());
        tracer.endSpan(&span);
    }

    std.debug.print("  Waiting for collector to process compressed traces...\n", .{});
    clock.sleep(2 * std.time.ns_per_s);

    std.debug.print("  Successfully sent {d} compressed trace spans\n", .{num_spans});
    std.debug.print("  Waiting for traces JSON file with compressed data...\n", .{});

    const json_content = common.waitForFileContent(allocator, io, tmp_dir, "traces.json", "test-span-compressed", 20) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            const stale_content = common.readJsonFile(allocator, io, tmp_dir, "traces.json") catch {
                std.debug.print("  ERROR: Could not read traces.json\n", .{});
                return error.CompressedTracesNotReceivedByCollector;
            };
            defer allocator.free(stale_content);
            std.debug.print("  ERROR: Compressed traces JSON doesn't contain expected data\n", .{});
            std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{stale_content[0..@min(stale_content.len, 500)]});
            return error.CompressedTracesNotReceivedByCollector;
        }
        return err;
    };
    defer allocator.free(json_content);

    const has_compressed_span = std.mem.indexOf(u8, json_content, "test-span-compressed") != null;
    const has_resource_spans = std.mem.indexOf(u8, json_content, "resourceSpans") != null or
        std.mem.indexOf(u8, json_content, "resource_spans") != null;
    const has_compression_attr = std.mem.indexOf(u8, json_content, "gzip") != null;

    if (!has_compressed_span or !has_resource_spans) {
        std.debug.print("  ERROR: Compressed traces JSON doesn't contain expected data\n", .{});
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.CompressedTracesNotReceivedByCollector;
    }

    std.debug.print("  ✓ Compressed traces JSON validated - found {d} test spans\n", .{num_spans});
    if (has_compression_attr) {
        std.debug.print("  ✓ Compression attribute 'gzip' found in traces\n", .{});
    }
}
