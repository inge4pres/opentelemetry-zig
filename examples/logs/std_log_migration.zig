const std = @import("std");
const sdk = @import("opentelemetry-sdk");

// Override std.log to use OpenTelemetry bridge
pub const std_options: std.Options = .{
    .logFn = sdk.logs.std_log_bridge.logFn,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("OpenTelemetry std.log Bridge - Migration Example\n", .{});
    std.debug.print("=================================================\n\n", .{});
    std.debug.print("This example demonstrates dual-mode logging:\n", .{});
    std.debug.print("- Logs are sent to OpenTelemetry exporters\n", .{});
    std.debug.print("- Logs ALSO appear on stderr (for compatibility)\n\n", .{});

    // Create a stdout exporter
    const stdout_file = std.fs.File.stdout();
    var stdout_exporter = sdk.logs.StdoutExporter.init(stdout_file.deprecatedWriter());
    const exporter = stdout_exporter.asLogRecordExporter();

    // Create a batching processor (more realistic for production)
    var batch_processor = try sdk.logs.BatchingLogRecordProcessor.init(allocator, exporter, .{
        .max_queue_size = 100,
        .scheduled_delay_millis = 1000,
        .max_export_batch_size = 10,
    });
    defer {
        const processor = batch_processor.asLogRecordProcessor();
        processor.shutdown() catch {};
        batch_processor.deinit();
    }
    const processor = batch_processor.asLogRecordProcessor();

    // Create a logger provider with resource attributes
    const service_name: []const u8 = "migration-example";
    const service_version: []const u8 = "1.0.0";
    const resource = try sdk.attributes.Attributes.from(allocator, .{
        "service.name",    service_name,
        "service.version", service_version,
    });
    defer if (resource) |r| allocator.free(r);

    var provider = try sdk.logs.LoggerProvider.init(allocator, resource);
    defer provider.deinit();

    // Add the processor
    try provider.addLogRecordProcessor(processor);

    // Configure the std.log bridge in DUAL MODE
    try sdk.logs.std_log_bridge.configure(.{
        .provider = provider,
        .also_log_to_stderr = true, // DUAL MODE: Send to both OTel AND stderr
        .include_scope_attribute = true,
        .include_source_location = true,
    });
    defer sdk.logs.std_log_bridge.shutdown();

    std.debug.print("Starting application with dual-mode logging...\n", .{});
    std.debug.print("(You should see logs both in OTel format AND on stderr)\n\n", .{});

    // Use standard std.log - logs go to BOTH destinations
    std.log.info("Application starting", .{});
    std.log.info("Configuration loaded from environment", .{});

    // Simulate application lifecycle
    try runApplication();

    std.debug.print("\n\nShutting down...\n", .{});

    // Force flush before shutdown to ensure all batched logs are exported
    try provider.forceFlush();
    try provider.shutdown();

    std.debug.print("Done! All logs were sent to both OpenTelemetry and stderr.\n", .{});
}

fn runApplication() !void {
    std.log.info("Initializing database connection", .{});

    // Simulate database connection
    std.log.debug("Connecting to database at localhost:5432", .{});
    std.log.info("Database connection established", .{});

    // Simulate processing
    for (0..3) |i| {
        std.log.info("Processing batch {d}/3", .{i + 1});
        std.log.debug("Fetching records from database", .{});

        if (i == 1) {
            std.log.warn("Slow query detected, took 2.5s", .{});
        }
    }

    std.log.info("All batches processed successfully", .{});
}
