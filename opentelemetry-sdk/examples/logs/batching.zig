const std = @import("std");
const clock = @import("clock");
const sdk = @import("opentelemetry-sdk");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.debug.print("OpenTelemetry Logs SDK - Batching Example\n", .{});
    std.debug.print("==========================================\n\n", .{});

    // Create a stdout exporter
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stdout_exporter = sdk.logs.StdoutExporter.init(&stdout_writer.interface);
    const exporter = stdout_exporter.asLogRecordExporter();

    // Create a batching processor with custom config
    var batching_processor = try sdk.logs.BatchingLogRecordProcessor.init(allocator, io, exporter, .{
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
    var provider = try sdk.logs.LoggerProvider.init(allocator, io, null);
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
        logger.emit(.info, "Batched log message", .{});
        clock.sleep(50 * std.time.ns_per_ms); // Small delay
    }

    std.debug.print("\n\nWaiting for background export...\n", .{});
    clock.sleep(500 * std.time.ns_per_ms);

    std.debug.print("Force flushing remaining logs...\n", .{});
    try provider.forceFlush();

    std.debug.print("\nShutting down...\n", .{});
    try provider.shutdown();

    std.debug.print("Done!\n", .{});
}
