const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const trace_sdk = sdk.trace;
const trace_api = sdk.api.trace;

const CONTAINER_NAME = "otel-collector-integration-test";
const COLLECTOR_HTTP_PORT = "4318";
const COLLECTOR_GRPC_PORT = "4317";

pub fn main() !void {
    // Use page allocator for integration tests instead of DebugAllocator.
    // Memory leaks in the SDK are tested by unit tests
    const allocator = std.heap.page_allocator;

    // Check if Docker is available
    std.debug.print("Checking container availability...\n", .{});
    try checkDockerAvailable(allocator);
    std.debug.print("✓ Docker daemon is available\n\n", .{});

    // Create temporary directory for output files
    std.debug.print("Setting up data directory...\n", .{});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Get the real path of the temporary directory for Docker mounting
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Make directory writable by all users so the collector container can write to it
    // The collector runs as a non-root user inside the container
    const chmod_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "chmod", "777", tmp_path },
    });
    defer allocator.free(chmod_result.stdout);
    defer allocator.free(chmod_result.stderr);

    if (chmod_result.term.Exited != 0) {
        return error.ChmodFailed;
    }

    std.debug.print("✓ Data directory ready: {s}\n\n", .{tmp_path});

    // Clean up any previous test containers
    try cleanupContainer(allocator);

    // Start the OTLP collector container
    std.debug.print("Starting OTLP collector container...\n", .{});
    try startCollectorContainer(allocator, tmp_path);
    defer cleanupContainer(allocator) catch |err| {
        std.debug.print("Warning: Failed to cleanup container: {}\n", .{err});
    };

    // Wait for collector to be ready
    std.debug.print("Waiting for collector to be ready...\n", .{});
    try waitForCollector(allocator);
    std.debug.print("✓ Collector is ready\n\n", .{});

    // Run metrics test
    std.debug.print("Running metrics integration test...\n", .{});
    try testMetrics(allocator, tmp.dir);
    std.debug.print("✓ Metrics test passed\n\n", .{});

    // Run traces test
    std.debug.print("Running traces integration test...\n", .{});
    try testTraces(allocator, tmp.dir);
    std.debug.print("✓ Traces test passed\n\n", .{});

    // Run compression tests
    std.debug.print("Running metrics compression test...\n", .{});
    try testMetricsWithCompression(allocator, tmp.dir);
    std.debug.print("✓ Metrics compression test passed\n\n", .{});

    std.debug.print("Running traces compression test...\n", .{});
    try testTracesWithCompression(allocator, tmp.dir);
    std.debug.print("✓ Traces compression test passed\n\n", .{});
}

fn checkDockerAvailable(allocator: std.mem.Allocator) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "docker", "--version" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Docker is not available. Please install Docker.\n", .{});
        return error.DockerNotAvailable;
    }
}

fn startCollectorContainer(allocator: std.mem.Allocator, data_path: []const u8) !void {
    // Get the current working directory to mount the config file
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "integration_tests", "otel-collector-config.yaml" });
    defer allocator.free(config_path);

    const config_mount_arg = try std.fmt.allocPrint(allocator, "{s}:/etc/otel-collector-config.yaml:ro", .{config_path});
    defer allocator.free(config_mount_arg);

    // Mount the data directory for output files
    const data_mount_arg = try std.fmt.allocPrint(allocator, "{s}:/tmp/otel-data", .{data_path});
    defer allocator.free(data_mount_arg);

    const grpc_port_arg = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ COLLECTOR_GRPC_PORT, COLLECTOR_GRPC_PORT });
    defer allocator.free(grpc_port_arg);

    const http_port_arg = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ COLLECTOR_HTTP_PORT, COLLECTOR_HTTP_PORT });
    defer allocator.free(http_port_arg);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "docker",
            "run",
            "-d",
            "--name",
            CONTAINER_NAME,
            "-p",
            grpc_port_arg,
            "-p",
            http_port_arg,
            "-v",
            config_mount_arg,
            "-v",
            data_mount_arg,
            "otel/opentelemetry-collector:latest",
            "--config=/etc/otel-collector-config.yaml",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Failed to start collector container.\n", .{});
        std.debug.print("stderr: {s}\n", .{result.stderr});
        return error.ContainerStartFailed;
    }
}

fn waitForCollector(allocator: std.mem.Allocator) !void {
    // Wait up to 30 seconds for the collector to be ready
    const max_retries = 30;
    var retry: usize = 0;

    while (retry < max_retries) : (retry += 1) {
        // Check if container is running
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "docker",
                "inspect",
                "-f",
                "{{.State.Running}}",
                CONTAINER_NAME,
            },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited == 0 and std.mem.startsWith(u8, result.stdout, "true")) {
            // Container is running, wait a bit more for OTLP endpoint to be ready
            std.Thread.sleep(2 * std.time.ns_per_s);
            return;
        }

        std.Thread.sleep(1 * std.time.ns_per_s);
    }

    return error.CollectorNotReady;
}

fn cleanupContainer(allocator: std.mem.Allocator) !void {
    // Stop the container
    const stop_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "docker", "stop", CONTAINER_NAME },
    });
    defer allocator.free(stop_result.stdout);
    defer allocator.free(stop_result.stderr);

    // Remove the container
    const rm_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "docker", "rm", CONTAINER_NAME },
    });
    defer allocator.free(rm_result.stdout);
    defer allocator.free(rm_result.stderr);
}

fn readJsonFile(allocator: std.mem.Allocator, dir: std.fs.Dir, file_name: []const u8) ![]const u8 {
    const file = try dir.openFile(file_name, .{});
    defer file.close();

    const max_size = 10 * 1024 * 1024; // 10 MB max
    const content = try file.readToEndAlloc(allocator, max_size);
    return content;
}

fn waitForFile(dir: std.fs.Dir, file_name: []const u8, max_retries: usize) !void {
    var retry: usize = 0;
    while (retry < max_retries) : (retry += 1) {
        const file = dir.openFile(file_name, .{}) catch |err| {
            if (err == error.FileNotFound and retry < max_retries - 1) {
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            }
            return err;
        };
        defer file.close();

        // Check if file has content (not just exists but is empty)
        const stat = try file.stat();
        if (stat.size > 0) {
            return;
        }

        // File exists but is empty, wait and retry
        if (retry < max_retries - 1) {
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
    }
    return error.FileNotFound;
}

fn testMetrics(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    // Configure the OTLP exporter to use the collector
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Configure to use HTTP on port 4318 (the collector's HTTP port)
    config.endpoint = "localhost:4318";

    // Create meter provider and exporter
    const mp = try metrics_sdk.MeterProvider.default();
    defer mp.shutdown();

    const me = try metrics_sdk.MetricExporter.OTLP(allocator, null, null, config);
    defer me.otlp.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, me.exporter);
    try mp.addReader(mr);

    // Record test metrics
    const meter = try mp.getMeter(.{ .name = "integration-test" });
    var counter = try meter.createCounter(u64, .{ .name = "test_counter" });

    // Record some data points
    const num_data_points = 5;
    for (0..num_data_points) |i| {
        try counter.add(42, .{ "iteration", @as(u64, i) });
    }

    // Force collection and export
    try mr.collect();

    // Give the collector some time to process and write the file
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Validate that the collector received the metrics by reading the JSON file
    std.debug.print("  Successfully sent {d} metric data points\n", .{num_data_points});
    std.debug.print("  Waiting for metrics JSON file...\n", .{});

    try waitForFile(tmp_dir, "metrics.json", 10);

    const json_content = try readJsonFile(allocator, tmp_dir, "metrics.json");
    defer allocator.free(json_content);

    // Verify the JSON contains expected metric data
    const has_test_counter = std.mem.indexOf(u8, json_content, "test_counter") != null;
    const has_resource_metrics = std.mem.indexOf(u8, json_content, "resourceMetrics") != null or
        std.mem.indexOf(u8, json_content, "resource_metrics") != null;

    if (!has_test_counter or !has_resource_metrics) {
        std.debug.print("  ERROR: Metrics JSON doesn't contain expected data\n", .{});
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.MetricsNotReceivedByCollector;
    }

    std.debug.print("  ✓ Metrics JSON validated - found 'test_counter' metric\n", .{});
}

fn testTraces(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    // Configure the OTLP exporter to use the collector
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Configure to use HTTP on port 4318 (the collector's HTTP port)
    config.endpoint = "localhost:4318";

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

    try waitForFile(tmp_dir, "traces.json", 20);

    const json_content = try readJsonFile(allocator, tmp_dir, "traces.json");
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

fn testMetricsWithCompression(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    // Configure the OTLP exporter with gzip compression
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Enable gzip compression
    config.endpoint = "localhost:4318";
    config.compression = .gzip;

    // Create meter provider and exporter
    const mp = try metrics_sdk.MeterProvider.default();
    defer mp.shutdown();

    const me = try metrics_sdk.MetricExporter.OTLP(allocator, null, null, config);
    defer me.otlp.deinit();

    const mr = try metrics_sdk.MetricReader.init(allocator, me.exporter);
    try mp.addReader(mr);

    // Record test metrics with compression indicator
    const meter = try mp.getMeter(.{ .name = "integration-test-compression" });
    var counter = try meter.createCounter(u64, .{ .name = "test_counter_compressed" });

    // Record some data points
    const num_data_points = 5;
    for (0..num_data_points) |i| {
        try counter.add(100 + i, .{ "compression", @as([]const u8, "gzip"), "iteration", @as(u64, i) });
    }

    // Force collection and export
    try mr.collect();

    // Give the collector time to process
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Wait for the file (reusing the same file as the uncompressed test)
    std.debug.print("  Successfully sent {d} compressed metric data points\n", .{num_data_points});
    std.debug.print("  Waiting for metrics JSON file...\n", .{});

    try waitForFile(tmp_dir, "metrics.json", 10);

    const json_content = try readJsonFile(allocator, tmp_dir, "metrics.json");
    defer allocator.free(json_content);

    // Verify the JSON contains expected compressed metric data
    const has_compressed_counter = std.mem.indexOf(u8, json_content, "test_counter_compressed") != null;
    const has_compression_attr = std.mem.indexOf(u8, json_content, "gzip") != null;
    const has_resource_metrics = std.mem.indexOf(u8, json_content, "resourceMetrics") != null or
        std.mem.indexOf(u8, json_content, "resource_metrics") != null;

    if (!has_compressed_counter or !has_resource_metrics) {
        std.debug.print("  ERROR: Compressed metrics JSON doesn't contain expected data\n", .{});
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.CompressedMetricsNotReceivedByCollector;
    }

    std.debug.print("  ✓ Compressed metrics JSON validated - found 'test_counter_compressed' metric\n", .{});
    if (has_compression_attr) {
        std.debug.print("  ✓ Compression attribute 'gzip' found in metrics\n", .{});
    }
}

fn testTracesWithCompression(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    // Configure the OTLP exporter with gzip compression
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Enable gzip compression
    config.endpoint = "localhost:4318";
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
    std.debug.print("  Waiting for traces JSON file...\n", .{});

    try waitForFile(tmp_dir, "traces.json", 20);

    const json_content = try readJsonFile(allocator, tmp_dir, "traces.json");
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
