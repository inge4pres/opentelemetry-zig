const std = @import("std");
const sdk = @import("opentelemetry-sdk");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.debug.print("OpenTelemetry Logs SDK Example\n", .{});
    std.debug.print("===============================\n\n", .{});

    // Create a stdout exporter
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_exporter = sdk.logs.StdoutExporter.init(std.Io.File.stdout().writer(io, &stdout_buffer));
    const exporter = stdout_exporter.asLogRecordExporter();

    // Create a simple processor
    var simple_processor = sdk.logs.SimpleLogRecordProcessor.init(allocator, io, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    // Create a logger provider
    var provider = try sdk.logs.LoggerProvider.init(allocator, io, null);
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
    logger.emit(.info, "Application started", .{});

    logger.emit(.debug, "Debug message with details", .{});

    // Emit with attributes
    const attrs = [_]sdk.attributes.Attribute{
        .{ .key = "user.id", .value = .{ .int = 12345 } },
        .{ .key = "request.path", .value = .{ .string = "/api/users" } },
    };
    logger.emit(.info, "Processing request", .{ .attributes = &attrs });

    logger.emit(.err, "Something went wrong!", .{});

    std.debug.print("\n\nShutting down...\n", .{});

    // Shutdown (flushes all pending logs)
    try provider.shutdown();

    std.debug.print("Done!\n", .{});
}
