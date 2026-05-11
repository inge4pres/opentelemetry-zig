const std = @import("std");
const clock = @import("clock");
const sdk = @import("opentelemetry-sdk");
const logs_sdk = sdk.logs;
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var ctx = try common.setupTestContext(allocator, io, "logs");
    defer common.cleanupTestContext(&ctx, io);

    std.debug.print("Running logs integration test...\n", .{});
    try testLogs(allocator, io, init.environ_map, ctx.tmp_dir);
    std.debug.print("✓ Logs test passed\n\n", .{});

    std.debug.print("Running logs compression test...\n", .{});
    try testLogsWithCompression(allocator, io, init.environ_map, ctx.tmp_dir);
    std.debug.print("✓ Logs compression test passed\n\n", .{});
}

fn testLogs(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    tmp_dir: std.Io.Dir,
) !void {
    var config = try sdk.otlp.ConfigOptions.init(allocator, env_map);
    defer config.deinit();

    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;

    var otlp_exporter = try logs_sdk.OTLPExporter.init(allocator, io, config);
    defer otlp_exporter.deinit();
    const exporter = otlp_exporter.asLogRecordExporter();

    var simple_processor = logs_sdk.SimpleLogRecordProcessor.init(allocator, io, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    const service_name: []const u8 = "integration-test";
    const resource_attrs = try sdk.Attributes.from(allocator, .{
        "service.name", service_name,
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);

    var provider = try logs_sdk.LoggerProvider.init(allocator, io, resource_attrs);
    defer provider.deinit();

    try provider.addLogRecordProcessor(processor);

    const scope = sdk.scope.InstrumentationScope{
        .name = "integration-test",
        .version = "1.0.0",
    };
    const logger = try provider.getLogger(scope);

    const num_logs = 5;
    logger.emit(.trace, "Test trace log", .{});
    logger.emit(.debug, "Test debug log", .{});
    logger.emit(.info, "Test info log", .{});
    logger.emit(.warn, "Test warning log", .{});
    logger.emit(.err, "Test error log", .{});

    const attrs = [_]sdk.attributes.Attribute{
        .{ .key = "test.iteration", .value = .{ .int = 1 } },
        .{ .key = "test.name", .value = .{ .string = "integration-test" } },
    };
    logger.emit(.info, "Test log with attributes", .{ .attributes = &attrs });

    try provider.shutdown();

    clock.sleep(1 * std.time.ns_per_s);

    std.debug.print("  Successfully sent {d} log records\n", .{num_logs + 1});
    std.debug.print("  Waiting for logs JSON file...\n", .{});

    try common.waitForFile(io, tmp_dir, "logs.json", 10);

    const json_content = try common.readJsonFile(allocator, io, tmp_dir, "logs.json");
    defer allocator.free(json_content);

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

fn testLogsWithCompression(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    tmp_dir: std.Io.Dir,
) !void {
    var config = try sdk.otlp.ConfigOptions.init(allocator, env_map);
    defer config.deinit();

    config.endpoint = "localhost:" ++ common.COLLECTOR_HTTP_PORT;
    config.compression = .gzip;

    var otlp_exporter = try logs_sdk.OTLPExporter.init(allocator, io, config);
    defer otlp_exporter.deinit();
    const exporter = otlp_exporter.asLogRecordExporter();

    var simple_processor = logs_sdk.SimpleLogRecordProcessor.init(allocator, io, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    const service_name: []const u8 = "integration-test-compression";
    const resource_attrs = try sdk.Attributes.from(allocator, .{
        "service.name", service_name,
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);

    var provider = try logs_sdk.LoggerProvider.init(allocator, io, resource_attrs);
    defer provider.deinit();

    try provider.addLogRecordProcessor(processor);

    const scope = sdk.scope.InstrumentationScope{
        .name = "integration-test-compression",
        .version = "1.0.0",
    };
    const logger = try provider.getLogger(scope);

    const num_logs = 3;
    const attrs = [_]sdk.attributes.Attribute{
        .{ .key = "compression", .value = .{ .string = "gzip" } },
        .{ .key = "test.type", .value = .{ .string = "compression" } },
    };

    logger.emit(.info, "Compressed log 1", .{ .attributes = &attrs });
    logger.emit(.info, "Compressed log 2", .{ .attributes = &attrs });
    logger.emit(.info, "Compressed log 3", .{ .attributes = &attrs });

    try provider.shutdown();

    clock.sleep(1 * std.time.ns_per_s);

    std.debug.print("  Successfully sent {d} compressed log records\n", .{num_logs});
    std.debug.print("  Waiting for logs JSON file with compressed data...\n", .{});

    const json_content = common.waitForFileContent(allocator, io, tmp_dir, "logs.json", "Compressed log", 15) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            const stale_content = common.readJsonFile(allocator, io, tmp_dir, "logs.json") catch {
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
