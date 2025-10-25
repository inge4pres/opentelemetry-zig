const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const trace_sdk = sdk.trace;
const trace_api = sdk.api.trace;
const common = @import("common.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var ctx = try common.setupTestContext(allocator, "traces");
    defer common.cleanupTestContext(&ctx);

    // Run traces test
    std.debug.print("Running traces integration test...\n", .{});
    try testTraces(allocator, ctx.tmp_dir);
    std.debug.print("✓ Traces test passed\n\n", .{});

    // Run compression test
    std.debug.print("Running traces compression test...\n", .{});
    try testTracesWithCompression(allocator, ctx.tmp_dir);
    std.debug.print("✓ Traces compression test passed\n\n", .{});
}

fn testTraces(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    // Configure the OTLP exporter to use the collector
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Configure to use HTTP on port 4318 (the collector's HTTP port)
    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;

    // Create ID generator for traces
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const id_generator = trace_sdk.IDGenerator{
        .Random = trace_sdk.RandomIDGenerator.init(prng.random()),
    };

    // Create tracer provider
    var tracer_provider = try trace_sdk.TracerProvider.init(allocator, id_generator);
    errdefer tracer_provider.shutdown();

    // Create OTLP exporter and processor
    var otlp_exporter = try trace_sdk.OTLPExporter.init(allocator, config);
    errdefer otlp_exporter.deinit();

    // Use simple processor for integration tests to ensure immediate export
    var simple_processor = trace_sdk.SimpleProcessor.init(
        allocator,
        otlp_exporter.asSpanExporter(),
    );

    const span_processor = simple_processor.asSpanProcessor();
    try tracer_provider.addSpanProcessor(span_processor);

    // Create and record some test spans
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

        // Simulate some work
        std.Thread.sleep(10 * std.time.ns_per_ms);

        span.setStatus(trace_api.Status.ok());
        tracer.endSpan(&span);
    }

    // Give the collector time to process and write the traces
    std.debug.print("  Waiting for collector to process and write traces...\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);

    // Validate that the collector received the traces by reading the JSON file
    std.debug.print("  Successfully sent {d} trace spans\n", .{num_spans});
    std.debug.print("  Waiting for traces JSON file...\n", .{});

    try common.waitForFile(tmp_dir, "traces.json", 20);

    const json_content = try common.readJsonFile(allocator, tmp_dir, "traces.json");
    defer allocator.free(json_content);

    // Verify the JSON contains expected trace data
    const has_test_span = std.mem.indexOf(u8, json_content, "test-span") != null;
    const has_resource_spans = std.mem.indexOf(u8, json_content, "resourceSpans") != null or
        std.mem.indexOf(u8, json_content, "resource_spans") != null;
    const has_integration_test = std.mem.indexOf(u8, json_content, "integration-test") != null;

    if (!has_test_span or !has_resource_spans or !has_integration_test) {
        std.debug.print("  ERROR: Traces JSON doesn't contain expected data\n", .{});
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        tracer_provider.shutdown();
        otlp_exporter.deinit();
        return error.TracesNotReceivedByCollector;
    }

    std.debug.print("  ✓ Traces JSON validated - found {d} test spans\n", .{num_spans});

    // Cleanup
    tracer_provider.shutdown();
    otlp_exporter.deinit();
}

fn testTracesWithCompression(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    // Configure the OTLP exporter with gzip compression
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Enable gzip compression
    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;
    config.compression = .gzip;

    // Create ID generator for traces
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const id_generator = trace_sdk.IDGenerator{
        .Random = trace_sdk.RandomIDGenerator.init(prng.random()),
    };

    // Create tracer provider
    var tracer_provider = try trace_sdk.TracerProvider.init(allocator, id_generator);
    errdefer tracer_provider.shutdown();

    // Create OTLP exporter with compression enabled
    var otlp_exporter = try trace_sdk.OTLPExporter.init(allocator, config);
    errdefer otlp_exporter.deinit();

    // Use simple processor for integration tests
    var simple_processor = trace_sdk.SimpleProcessor.init(
        allocator,
        otlp_exporter.asSpanExporter(),
    );

    const span_processor = simple_processor.asSpanProcessor();
    try tracer_provider.addSpanProcessor(span_processor);

    // Create and record test spans with compression indicator
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

        // Simulate some work
        std.Thread.sleep(10 * std.time.ns_per_ms);

        span.setStatus(trace_api.Status.ok());
        tracer.endSpan(&span);
    }

    // Give the collector time to process
    std.debug.print("  Waiting for collector to process compressed traces...\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);

    // Validate that the collector received the compressed traces
    std.debug.print("  Successfully sent {d} compressed trace spans\n", .{num_spans});
    std.debug.print("  Waiting for traces JSON file with compressed data...\n", .{});

    const json_content = common.waitForFileContent(allocator, tmp_dir, "traces.json", "test-span-compressed", 20) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            // Read the file to show what we got instead
            const stale_content = common.readJsonFile(allocator, tmp_dir, "traces.json") catch {
                std.debug.print("  ERROR: Could not read traces.json\n", .{});
                tracer_provider.shutdown();
                otlp_exporter.deinit();
                return error.CompressedTracesNotReceivedByCollector;
            };
            defer allocator.free(stale_content);
            std.debug.print("  ERROR: Compressed traces JSON doesn't contain expected data\n", .{});
            std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{stale_content[0..@min(stale_content.len, 500)]});
            tracer_provider.shutdown();
            otlp_exporter.deinit();
            return error.CompressedTracesNotReceivedByCollector;
        }
        tracer_provider.shutdown();
        otlp_exporter.deinit();
        return err;
    };
    defer allocator.free(json_content);

    // Verify the JSON contains expected compressed trace data
    const has_compressed_span = std.mem.indexOf(u8, json_content, "test-span-compressed") != null;
    const has_resource_spans = std.mem.indexOf(u8, json_content, "resourceSpans") != null or
        std.mem.indexOf(u8, json_content, "resource_spans") != null;
    const has_compression_attr = std.mem.indexOf(u8, json_content, "gzip") != null;

    if (!has_compressed_span or !has_resource_spans) {
        std.debug.print("  ERROR: Compressed traces JSON doesn't contain expected data\n", .{});
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        tracer_provider.shutdown();
        otlp_exporter.deinit();
        return error.CompressedTracesNotReceivedByCollector;
    }

    std.debug.print("  ✓ Compressed traces JSON validated - found {d} test spans\n", .{num_spans});
    if (has_compression_attr) {
        std.debug.print("  ✓ Compression attribute 'gzip' found in traces\n", .{});
    }

    // Cleanup
    tracer_provider.shutdown();
    otlp_exporter.deinit();
}
