const std = @import("std");
const sdk = @import("opentelemetry-sdk");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("OpenTelemetry Logs SDK - Batching Example\n", .{});
    std.debug.print("==========================================\n\n", .{});

    // Create a stdout exporter
    var stdout_exporter = sdk.logs.StdoutExporter.init(std.io.getStdOut().writer());
    const exporter = stdout_exporter.asLogRecordExporter();

    // Create a batching processor with custom config
    var batching_processor = try sdk.logs.BatchingLogRecordProcessor.init(allocator, exporter, .{
        .max_queue_size = 1024,
        .max_export_batch_size = 5, // Export every 5 logs
        .scheduled_delay_millis = 1000, // Or every 1 second
    });
    defer {
        const processor = batching_processor.asLogRecordProcessor();
        processor.shutdown() catch {};
        batching_processor.deinit();
    }

    const processor = batching_processor.asLogRecordProcessor();

    // Create a logger provider
    var provider = try sdk.logs.LoggerProvider.init(allocator);
    defer provider.deinit();

    // Add the batching processor
    try provider.addLogRecordProcessor(processor);

    // Get a logger
    const scope = sdk.scope.InstrumentationScope{
        .name = "example.batching",
        .version = "1.0.0",
    };
    const logger = try provider.getLogger(scope);

    std.debug.print("Emitting 10 log records (batch size = 5)...\n\n", .{});

    // Emit 10 logs quickly - should trigger 2 batches
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        logger.emit(9, "INFO", "Batched log message", null);
        std.time.sleep(50 * std.time.ns_per_ms); // Small delay
    }

    std.debug.print("\n\nWaiting for background export...\n", .{});
    std.time.sleep(500 * std.time.ns_per_ms);

    std.debug.print("Force flushing remaining logs...\n", .{});
    try provider.forceFlush();

    std.debug.print("\nShutting down...\n", .{});
    try provider.shutdown();

    std.debug.print("Done!\n", .{});
}
