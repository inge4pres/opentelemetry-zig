const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const logs_sdk = sdk.logs;
const common = @import("common.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var ctx = try common.setupTestContext(allocator, "logs");
    defer common.cleanupTestContext(&ctx);

    // Run logs test
    std.debug.print("Running logs integration test...\n", .{});
    try testLogs(allocator, ctx.tmp_dir);
    std.debug.print("✓ Logs test passed\n\n", .{});

    // Run compression test
    std.debug.print("Running logs compression test...\n", .{});
    try testLogsWithCompression(allocator, ctx.tmp_dir);
    std.debug.print("✓ Logs compression test passed\n\n", .{});
}

fn testLogs(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    // Configure the OTLP exporter to use the collector
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Configure to use HTTP on port 4318 (the collector's HTTP port)
    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;

    // Create OTLP exporter
    var otlp_exporter = try logs_sdk.OTLPExporter.init(allocator, config);
    defer otlp_exporter.deinit();
    const exporter = otlp_exporter.asLogRecordExporter();

    // Create a simple processor (exports immediately)
    var simple_processor = logs_sdk.SimpleLogRecordProcessor.init(allocator, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    // Create resource attributes
    const service_name: []const u8 = "integration-test";
    const resource_attrs = try sdk.Attributes.from(allocator, .{
        "service.name", service_name,
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);

    // Create a logger provider
    var provider = try logs_sdk.LoggerProvider.init(allocator, resource_attrs);
    defer provider.deinit();

    // Add the processor
    try provider.addLogRecordProcessor(processor);

    // Get a logger with instrumentation scope
    const scope = sdk.scope.InstrumentationScope{
        .name = "integration-test",
        .version = "1.0.0",
    };
    const logger = try provider.getLogger(scope);

    // Emit test log records with different severity levels
    const num_logs = 5;
    logger.emit(1, "TRACE", "Test trace log", null);
    logger.emit(5, "DEBUG", "Test debug log", null);
    logger.emit(9, "INFO", "Test info log", null);
    logger.emit(13, "WARN", "Test warning log", null);
    logger.emit(17, "ERROR", "Test error log", null);

    // Emit a log with attributes
    const attrs = [_]sdk.attributes.Attribute{
        .{ .key = "test.iteration", .value = .{ .int = 1 } },
        .{ .key = "test.name", .value = .{ .string = "integration-test" } },
    };
    logger.emit(9, "INFO", "Test log with attributes", &attrs);

    // Shutdown to flush logs
    try provider.shutdown();

    // Give the collector some time to process and write the file
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Validate that the collector received the logs by reading the JSON file
    std.debug.print("  Successfully sent {d} log records\n", .{num_logs + 1});
    std.debug.print("  Waiting for logs JSON file...\n", .{});

    try common.waitForFile(tmp_dir, "logs.json", 10);

    const json_content = try common.readJsonFile(allocator, tmp_dir, "logs.json");
    defer allocator.free(json_content);

    // Verify the JSON contains expected log data
    const has_test_logs = std.mem.indexOf(u8, json_content, "Test") != null;
    const has_resource_logs = std.mem.indexOf(u8, json_content, "resourceLogs") != null or
        std.mem.indexOf(u8, json_content, "resource_logs") != null;
    const has_integration_test = std.mem.indexOf(u8, json_content, "integration-test") != null;

    if (!has_test_logs or !has_resource_logs or !has_integration_test) {
        std.debug.print("  ERROR: Logs JSON doesn't contain expected data\n", .{});
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.LogsNotReceivedByCollector;
    }

    std.debug.print("  ✓ Logs JSON validated - found test log records\n", .{});
}

fn testLogsWithCompression(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    // Configure the OTLP exporter with gzip compression
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Enable gzip compression
    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;
    config.compression = .gzip;

    // Create OTLP exporter with compression
    var otlp_exporter = try logs_sdk.OTLPExporter.init(allocator, config);
    defer otlp_exporter.deinit();
    const exporter = otlp_exporter.asLogRecordExporter();

    // Create a simple processor
    var simple_processor = logs_sdk.SimpleLogRecordProcessor.init(allocator, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    // Create resource attributes with compression indicator
    const service_name: []const u8 = "integration-test-compression";
    const resource_attrs = try sdk.Attributes.from(allocator, .{
        "service.name", service_name,
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);

    // Create a logger provider
    var provider = try logs_sdk.LoggerProvider.init(allocator, resource_attrs);
    defer provider.deinit();

    // Add the processor
    try provider.addLogRecordProcessor(processor);

    // Get a logger with instrumentation scope
    const scope = sdk.scope.InstrumentationScope{
        .name = "integration-test-compression",
        .version = "1.0.0",
    };
    const logger = try provider.getLogger(scope);

    // Emit test log records with compression indicator
    const num_logs = 3;
    const attrs = [_]sdk.attributes.Attribute{
        .{ .key = "compression", .value = .{ .string = "gzip" } },
        .{ .key = "test.type", .value = .{ .string = "compression" } },
    };

    logger.emit(9, "INFO", "Compressed log 1", &attrs);
    logger.emit(9, "INFO", "Compressed log 2", &attrs);
    logger.emit(9, "INFO", "Compressed log 3", &attrs);

    // Shutdown to flush logs
    try provider.shutdown();

    // Give the collector time to process
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Validate that the collector received the compressed logs
    std.debug.print("  Successfully sent {d} compressed log records\n", .{num_logs});
    std.debug.print("  Waiting for logs JSON file with compressed data...\n", .{});

    const json_content = common.waitForFileContent(allocator, tmp_dir, "logs.json", "Compressed log", 15) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            // Read the file to show what we got instead
            const stale_content = common.readJsonFile(allocator, tmp_dir, "logs.json") catch {
                std.debug.print("  ERROR: Could not read logs.json\n", .{});
                return error.CompressedLogsNotReceivedByCollector;
            };
            defer allocator.free(stale_content);
            std.debug.print("  ERROR: Compressed logs JSON doesn't contain expected data\n", .{});
            std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{stale_content[0..@min(stale_content.len, 500)]});
            return error.CompressedLogsNotReceivedByCollector;
        }
        return err;
    };
    defer allocator.free(json_content);

    // Verify the JSON contains expected compressed log data
    const has_compressed_logs = std.mem.indexOf(u8, json_content, "Compressed log") != null;
    const has_resource_logs = std.mem.indexOf(u8, json_content, "resourceLogs") != null or
        std.mem.indexOf(u8, json_content, "resource_logs") != null;
    const has_compression_attr = std.mem.indexOf(u8, json_content, "gzip") != null;

    if (!has_compressed_logs or !has_resource_logs) {
        std.debug.print("  ERROR: Compressed logs JSON doesn't contain expected data\n", .{});
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.CompressedLogsNotReceivedByCollector;
    }

    std.debug.print("  ✓ Compressed logs JSON validated - found compressed log records\n", .{});
    if (has_compression_attr) {
        std.debug.print("  ✓ Compression attribute 'gzip' found in logs\n", .{});
    }
}
