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

    std.debug.print("OpenTelemetry std.log Bridge - Basic Example\n", .{});
    std.debug.print("=============================================\n\n", .{});

    // Create a stdout exporter
    const stdout_file = std.fs.File.stdout();
    var stdout_exporter = sdk.logs.StdoutExporter.init(stdout_file.deprecatedWriter());
    const exporter = stdout_exporter.asLogRecordExporter();

    // Create a simple processor
    var simple_processor = sdk.logs.SimpleLogRecordProcessor.init(allocator, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    // Create a logger provider
    var provider = try sdk.logs.LoggerProvider.init(allocator, null);
    defer provider.deinit();

    // Add the processor
    try provider.addLogRecordProcessor(processor);

    // Configure the std.log bridge
    try sdk.logs.std_log_bridge.configure(.{
        .provider = provider,
        .also_log_to_stderr = false, // Only log to OpenTelemetry
        .include_scope_attribute = true,
        .include_source_location = true,
    });
    defer sdk.logs.std_log_bridge.shutdown();

    std.debug.print("Using std.log (routed to OpenTelemetry)...\n\n", .{});

    // Now use standard std.log functions - they'll go to OpenTelemetry!
    std.log.info("Application started successfully", .{});
    std.log.debug("Debug information: processing {d} items", .{42});
    std.log.warn("Low memory warning: {d}% available", .{15});

    // Simulate some application work
    processRequest("user-123") catch |err| {
        std.log.err("Failed to process request: {}", .{err});
    };

    std.debug.print("\n\nShutting down...\n", .{});

    // Shutdown (flushes all pending logs)
    try provider.shutdown();

    std.debug.print("Done!\n", .{});
}

fn processRequest(user_id: []const u8) !void {
    std.log.info("Processing request for user: {s}", .{user_id});

    // Simulate some work
    std.log.debug("Validating user credentials", .{});
    std.log.debug("Loading user profile", .{});

    // Simulate an error
    std.log.err("Database connection timeout", .{});
    return error.DatabaseTimeout;
}
