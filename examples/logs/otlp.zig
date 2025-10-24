const std = @import("std");
const sdk = @import("opentelemetry-sdk");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("OpenTelemetry OTLP Logs Exporter Example\n", .{});
    std.debug.print("=========================================\n\n", .{});

    // Create OTLP configuration
    // This will use environment variables like:
    // - OTEL_EXPORTER_OTLP_ENDPOINT (default: http://localhost:4318)
    // - OTEL_EXPORTER_OTLP_LOGS_ENDPOINT (logs-specific override)
    // - OTEL_EXPORTER_OTLP_HEADERS (custom headers)
    // - OTEL_EXPORTER_OTLP_COMPRESSION (gzip compression)
    var otlp_config = try sdk.otlp.ConfigOptions.init(allocator);
    defer otlp_config.deinit();

    std.debug.print("OTLP Endpoint: {s}\n", .{otlp_config.endpoint});
    std.debug.print("OTLP Protocol: {s}\n\n", .{@tagName(otlp_config.protocol)});

    // Create OTLP exporter
    var otlp_exporter = try sdk.logs.OTLPExporter.init(allocator, otlp_config);
    defer otlp_exporter.deinit();
    const exporter = otlp_exporter.asLogRecordExporter();

    // Create a simple processor (exports immediately)
    // For production, consider using BatchingLogRecordProcessor instead
    var simple_processor = sdk.logs.SimpleLogRecordProcessor.init(allocator, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    // Create resource attributes to identify this service
    const service_name: []const u8 = "otlp-logs-example";
    const service_version: []const u8 = "1.0.0";
    const deployment_env: []const u8 = "development";
    const resource_attrs = try sdk.attributes.Attributes.from(allocator, .{
        "service.name",    service_name,
        "service.version", service_version,
        "deployment.env",  deployment_env,
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);

    // Create a logger provider with resource
    var provider = try sdk.logs.LoggerProvider.init(allocator, resource_attrs);
    defer provider.deinit();

    // Add the processor
    try provider.addLogRecordProcessor(processor);

    // Get a logger with instrumentation scope
    const scope = sdk.scope.InstrumentationScope{
        .name = "example.otlp.logs",
        .version = "1.0.0",
    };
    const logger = try provider.getLogger(scope);

    std.debug.print("Emitting log records to OTLP collector...\n\n", .{});

    // Emit logs with different severity levels
    logger.emit(1, "TRACE", "Trace level message - very detailed", null);
    logger.emit(5, "DEBUG", "Debug level message", null);
    logger.emit(9, "INFO", "Application started successfully", null);
    logger.emit(13, "WARN", "This is a warning message", null);
    logger.emit(17, "ERROR", "An error occurred", null);
    logger.emit(21, "FATAL", "Fatal error - application cannot continue", null);

    // Emit with attributes
    const attrs = [_]sdk.attributes.Attribute{
        .{ .key = "http.method", .value = .{ .string = "GET" } },
        .{ .key = "http.url", .value = .{ .string = "/api/users/123" } },
        .{ .key = "http.status_code", .value = .{ .int = 200 } },
        .{ .key = "http.response_time_ms", .value = .{ .double = 45.67 } },
    };
    logger.emit(9, "INFO", "HTTP request processed", &attrs);

    // Emit log with trace correlation (demonstrates distributed tracing integration)
    // In a real application, these would come from the current span context
    std.debug.print("Note: In production, trace_id and span_id would be extracted\n", .{});
    std.debug.print("      from active span context for distributed tracing.\n\n", .{});

    std.debug.print("\nLogs sent to OTLP collector at: {s}/v1/logs\n", .{otlp_config.endpoint});
    std.debug.print("\nShutting down...\n", .{});

    // Shutdown (flushes all pending logs)
    try provider.shutdown();

    std.debug.print("Done!\n\n", .{});
    std.debug.print("💡 Tip: Start an OTLP collector to receive logs:\n", .{});
    std.debug.print("   docker run -p 4318:4318 otel/opentelemetry-collector\n", .{});
    std.debug.print("\n   Or configure custom endpoint:\n", .{});
    std.debug.print("   OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 ./example\n", .{});
}
