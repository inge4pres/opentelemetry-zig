const std = @import("std");
const sdk = @import("opentelemetry-sdk");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("OpenTelemetry Logs SDK Example\n", .{});
    std.debug.print("===============================\n\n", .{});

    // Create a stdout exporter
    var stdout_exporter = sdk.logs.StdoutExporter.init(std.io.getStdOut().writer());
    const exporter = stdout_exporter.asLogRecordExporter();

    // Create a simple processor
    var simple_processor = sdk.logs.SimpleLogRecordProcessor.init(allocator, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    // Create a logger provider
    var provider = try sdk.logs.LoggerProvider.init(allocator);
    defer provider.deinit();

    // Add the processor
    try provider.addLogRecordProcessor(processor);

    // Get a logger
    const scope = sdk.scope.InstrumentationScope{
        .name = "example.basic",
        .version = "1.0.0",
    };
    const logger = try provider.getLogger(scope);

    std.debug.print("Emitting log records...\n\n", .{});

    // Emit some logs
    logger.emit(9, "INFO", "Application started", null);

    logger.emit(5, "DEBUG", "Debug message with details", null);

    // Emit with attributes
    const attrs = [_]sdk.attributes.Attribute{
        .{ .key = "user.id", .value = .{ .int = 12345 } },
        .{ .key = "request.path", .value = .{ .string = "/api/users" } },
    };
    logger.emit(9, "INFO", "Processing request", &attrs);

    logger.emit(17, "ERROR", "Something went wrong!", null);

    std.debug.print("\n\nShutting down...\n", .{});

    // Shutdown (flushes all pending logs)
    try provider.shutdown();

    std.debug.print("Done!\n", .{});
}
