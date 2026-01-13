//! OpenTelemetry Logs SDK C bindings.
//!
//! This module provides C-compatible wrappers for the Zig Logs SDK,
//! allowing C programs to use OpenTelemetry logging instrumentation.
//!
//! ## Usage from C
//!
//! ```c
//! #include "opentelemetry.h"
//!
//! // Create a logger provider
//! otel_logger_provider_t* provider = otel_logger_provider_create();
//!
//! // Add a log record processor with stdout exporter
//! otel_log_record_exporter_t* exporter = otel_log_record_exporter_stdout_create();
//! otel_log_record_processor_t* processor = otel_simple_log_record_processor_create(exporter);
//! otel_logger_provider_add_log_record_processor(provider, processor);
//!
//! // Get a logger
//! otel_logger_t* logger = otel_logger_provider_get_logger(provider, "my-library", "1.0.0", NULL);
//!
//! // Emit log records
//! otel_logger_emit(logger, OTEL_SEVERITY_INFO, "INFO", "Hello from C!", NULL, 0);
//!
//! // Cleanup
//! otel_logger_provider_shutdown(provider);
//! ```

const std = @import("std");
const LoggerProvider = @import("../api/logs/logger_provider.zig").LoggerProvider;
const Logger = @import("../api/logs/logger_provider.zig").Logger;
const ReadWriteLogRecord = @import("../api/logs/logger_provider.zig").ReadWriteLogRecord;
const ReadableLogRecord = @import("../api/logs/logger_provider.zig").ReadableLogRecord;
const LogRecordProcessor = @import("../sdk/logs/log_record_processor.zig").LogRecordProcessor;
const SimpleLogRecordProcessor = @import("../sdk/logs/log_record_processor.zig").SimpleLogRecordProcessor;
const LogRecordExporter = @import("../sdk/logs/log_record_exporter.zig").LogRecordExporter;
const StdoutExporter = @import("../sdk/logs/exporters/generic.zig").StdoutExporter;
const Attribute = @import("../attributes.zig").Attribute;
const InstrumentationScope = @import("../scope.zig").InstrumentationScope;

// ============================================================================
// Error Codes (shared with metrics/traces)
// ============================================================================

/// Error codes returned by C API functions.
pub const OtelStatus = enum(c_int) {
    ok = 0,
    error_out_of_memory = -1,
    error_invalid_argument = -2,
    error_invalid_state = -3,
    error_already_shutdown = -4,
    error_export_failed = -5,
    error_unknown = -99,
};

// ============================================================================
// Opaque Handle Types
// ============================================================================

/// Opaque handle to a LoggerProvider.
pub const OtelLoggerProvider = opaque {};

/// Opaque handle to a Logger.
pub const OtelLogger = opaque {};

/// Opaque handle to a LogRecordProcessor.
pub const OtelLogRecordProcessor = opaque {};

/// Opaque handle to a LogRecordExporter.
pub const OtelLogRecordExporter = opaque {};

// ============================================================================
// Severity Levels
// ============================================================================

/// Severity number values for logs (OpenTelemetry specification).
pub const OtelSeverityNumber = enum(c_int) {
    unspecified = 0,
    trace = 1,
    trace2 = 2,
    trace3 = 3,
    trace4 = 4,
    debug = 5,
    debug2 = 6,
    debug3 = 7,
    debug4 = 8,
    info = 9,
    info2 = 10,
    info3 = 11,
    info4 = 12,
    warn = 13,
    warn2 = 14,
    warn3 = 15,
    warn4 = 16,
    @"error" = 17,
    error2 = 18,
    error3 = 19,
    error4 = 20,
    fatal = 21,
    fatal2 = 22,
    fatal3 = 23,
    fatal4 = 24,
};

// ============================================================================
// Attribute Types (shared with metrics/traces)
// ============================================================================

/// Attribute value types for C API.
pub const OtelAttributeValueType = enum(c_int) {
    bool = 0,
    int = 1,
    double = 2,
    string = 3,
};

/// A key-value attribute pair for C API.
pub const OtelAttribute = extern struct {
    key: [*:0]const u8,
    value_type: OtelAttributeValueType,
    value: extern union {
        bool_value: bool,
        int_value: i64,
        double_value: f64,
        string_value: [*:0]const u8,
    },
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Get the global allocator used for C bindings.
fn getCAllocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

/// Convert C attribute array to Zig attribute slice.
fn convertAttributes(
    allocator: std.mem.Allocator,
    c_attrs: [*c]const OtelAttribute,
    count: usize,
) !?[]Attribute {
    if (count == 0 or c_attrs == null) return null;

    var attrs = try allocator.alloc(Attribute, count);
    errdefer allocator.free(attrs);

    for (0..count) |i| {
        const c_attr = c_attrs[i];
        const key = std.mem.span(c_attr.key);

        attrs[i] = .{
            .key = key,
            .value = switch (c_attr.value_type) {
                .bool => .{ .bool = c_attr.value.bool_value },
                .int => .{ .int = c_attr.value.int_value },
                .double => .{ .double = c_attr.value.double_value },
                .string => .{ .string = std.mem.span(c_attr.value.string_value) },
            },
        };
    }

    return attrs;
}

// ============================================================================
// LoggerProvider API
// ============================================================================

/// Create a new LoggerProvider.
///
/// Returns: Pointer to the LoggerProvider, or null on error.
pub fn loggerProviderCreate() callconv(.c) ?*OtelLoggerProvider {
    const allocator = getCAllocator();
    const provider = LoggerProvider.init(allocator, null) catch return null;
    return @ptrCast(provider);
}

/// Shutdown the LoggerProvider and release all resources.
///
/// After calling this function, the provider handle becomes invalid.
pub fn loggerProviderShutdown(provider: ?*OtelLoggerProvider) callconv(.c) void {
    if (provider) |p| {
        const lp: *LoggerProvider = @ptrCast(@alignCast(p));
        lp.shutdown() catch {};
        lp.deinit();
    }
}

/// Get a Logger from the LoggerProvider.
///
/// Parameters:
/// - provider: The LoggerProvider handle
/// - name: The name of the logger (null-terminated string)
/// - version: Optional version string (null-terminated, can be null)
/// - schema_url: Optional schema URL (null-terminated, can be null)
///
/// Returns: Pointer to the Logger, or null on error.
pub fn loggerProviderGetLogger(
    provider: ?*OtelLoggerProvider,
    name: [*:0]const u8,
    version: ?[*:0]const u8,
    schema_url: ?[*:0]const u8,
) callconv(.c) ?*OtelLogger {
    const p = provider orelse return null;
    const lp: *LoggerProvider = @ptrCast(@alignCast(p));

    const scope = InstrumentationScope{
        .name = std.mem.span(name),
        .version = if (version) |v| std.mem.span(v) else null,
        .schema_url = if (schema_url) |s| std.mem.span(s) else null,
    };

    const logger = lp.getLogger(scope) catch return null;
    return @ptrCast(logger);
}

/// Add a LogRecordProcessor to the LoggerProvider.
///
/// Returns: Status code indicating success or failure.
pub fn loggerProviderAddLogRecordProcessor(
    provider: ?*OtelLoggerProvider,
    processor: ?*OtelLogRecordProcessor,
) callconv(.c) OtelStatus {
    const p = provider orelse return .error_invalid_argument;
    const proc = processor orelse return .error_invalid_argument;

    const lp: *LoggerProvider = @ptrCast(@alignCast(p));
    const lrp: *LogRecordProcessor = @ptrCast(@alignCast(proc));

    lp.addLogRecordProcessor(lrp.*) catch |err| {
        return switch (err) {
            error.OutOfMemory => .error_out_of_memory,
            error.LoggerProviderShutdown => .error_already_shutdown,
        };
    };

    return .ok;
}

/// Force flush all log record processors.
///
/// Returns: Status code indicating success or failure.
pub fn loggerProviderForceFlush(provider: ?*OtelLoggerProvider) callconv(.c) OtelStatus {
    const p = provider orelse return .error_invalid_argument;
    const lp: *LoggerProvider = @ptrCast(@alignCast(p));

    lp.forceFlush() catch |err| {
        return switch (err) {
            error.LoggerProviderShutdown => .error_already_shutdown,
            else => .error_export_failed,
        };
    };

    return .ok;
}

// ============================================================================
// Logger API
// ============================================================================

/// Emit a log record.
///
/// Parameters:
/// - logger: The Logger handle
/// - severity_number: Severity level (use OtelSeverityNumber values)
/// - severity_text: Severity text (e.g., "INFO", "ERROR", null-terminated, can be null)
/// - body: Log message body (null-terminated, can be null)
/// - attributes: Array of attributes (can be null)
/// - attr_count: Number of attributes
///
/// Returns: Status code indicating success or failure.
pub fn loggerEmit(
    logger: ?*OtelLogger,
    severity_number: c_int,
    severity_text: ?[*:0]const u8,
    body: ?[*:0]const u8,
    attributes: [*c]const OtelAttribute,
    attr_count: usize,
) callconv(.c) OtelStatus {
    const l = logger orelse return .error_invalid_argument;
    const zigLogger: *Logger = @ptrCast(@alignCast(l));

    const allocator = getCAllocator();

    // Convert attributes
    const attrs = convertAttributes(allocator, attributes, attr_count) catch return .error_out_of_memory;
    defer if (attrs) |a| allocator.free(a);

    // Emit the log record
    zigLogger.emit(
        if (severity_number > 0) @intCast(severity_number) else null,
        if (severity_text) |st| std.mem.span(st) else null,
        if (body) |b| std.mem.span(b) else null,
        attrs,
    );

    return .ok;
}

/// Check if logging is enabled for the given severity.
///
/// This method is useful for avoiding expensive operations when logging is disabled.
///
/// Returns: true if logging is enabled, false otherwise.
pub fn loggerIsEnabled(
    logger: ?*OtelLogger,
    severity_number: c_int,
) callconv(.c) bool {
    const l = logger orelse return false;
    const zigLogger: *Logger = @ptrCast(@alignCast(l));

    // Use the enabled method with just severity
    const context = @import("../api/context/context.zig").Context.init();
    return zigLogger.enabled(.{
        .context = context,
        .severity = if (severity_number > 0) @intCast(severity_number) else null,
    });
}

// ============================================================================
// LogRecordExporter API
// ============================================================================

/// Internal wrapper for stdout exporter that holds the exporter together.
const StdoutLogExporterWrapper = struct {
    exporter: ?StdoutExporter = null,
    log_record_exporter: ?LogRecordExporter = null,

    fn init(self: *StdoutLogExporterWrapper) void {
        // Initialize the exporter with stdout
        self.exporter = StdoutExporter.init(std.fs.File.stdout().deprecatedWriter());
        // Now create the log record exporter interface
        self.log_record_exporter = self.exporter.?.asLogRecordExporter();
    }
};

/// Create a stdout LogRecordExporter for debugging.
///
/// Returns: Pointer to the LogRecordExporter, or null on error.
pub fn logRecordExporterStdoutCreate() callconv(.c) ?*OtelLogRecordExporter {
    const allocator = getCAllocator();

    // Allocate the wrapper on the heap so everything persists
    const wrapper = allocator.create(StdoutLogExporterWrapper) catch return null;
    wrapper.* = .{}; // Initialize with defaults
    wrapper.init(); // Then initialize the exporter

    if (wrapper.log_record_exporter) |*lre| {
        return @ptrCast(lre);
    }
    return null;
}

// ============================================================================
// LogRecordProcessor API
// ============================================================================

/// Create a SimpleLogRecordProcessor that exports logs immediately.
///
/// Parameters:
/// - exporter: The LogRecordExporter handle
///
/// Returns: Pointer to the LogRecordProcessor, or null on error.
pub fn simpleLogRecordProcessorCreate(exporter: ?*OtelLogRecordExporter) callconv(.c) ?*OtelLogRecordProcessor {
    const e = exporter orelse return null;
    const allocator = getCAllocator();

    const exp: *LogRecordExporter = @ptrCast(@alignCast(e));

    const storage = allocator.create(SimpleLogRecordProcessor) catch return null;
    storage.* = SimpleLogRecordProcessor.init(allocator, exp.*);

    const processor_ptr = allocator.create(LogRecordProcessor) catch {
        allocator.destroy(storage);
        return null;
    };
    processor_ptr.* = storage.asLogRecordProcessor();

    return @ptrCast(processor_ptr);
}

// ============================================================================
// C Export Declarations
// ============================================================================

comptime {
    // LoggerProvider exports
    @export(&loggerProviderCreate, .{ .name = "otel_logger_provider_create" });
    @export(&loggerProviderShutdown, .{ .name = "otel_logger_provider_shutdown" });
    @export(&loggerProviderGetLogger, .{ .name = "otel_logger_provider_get_logger" });
    @export(&loggerProviderAddLogRecordProcessor, .{ .name = "otel_logger_provider_add_log_record_processor" });
    @export(&loggerProviderForceFlush, .{ .name = "otel_logger_provider_force_flush" });

    // Logger exports
    @export(&loggerEmit, .{ .name = "otel_logger_emit" });
    @export(&loggerIsEnabled, .{ .name = "otel_logger_is_enabled" });

    // LogRecordExporter exports
    @export(&logRecordExporterStdoutCreate, .{ .name = "otel_log_record_exporter_stdout_create" });

    // LogRecordProcessor exports
    @export(&simpleLogRecordProcessorCreate, .{ .name = "otel_simple_log_record_processor_create" });
}

// ============================================================================
// Tests
// ============================================================================

test "logs C API - create logger provider" {
    const provider = loggerProviderCreate();
    try std.testing.expect(provider != null);
    defer loggerProviderShutdown(provider);
}

test "logs C API - get logger" {
    const provider = loggerProviderCreate();
    try std.testing.expect(provider != null);
    defer loggerProviderShutdown(provider);

    const logger = loggerProviderGetLogger(provider, "test-logger", "1.0.0", null);
    try std.testing.expect(logger != null);
}

test "logs C API - emit log record" {
    const provider = loggerProviderCreate();
    try std.testing.expect(provider != null);
    defer loggerProviderShutdown(provider);

    const logger = loggerProviderGetLogger(provider, "test-logger", null, null);
    try std.testing.expect(logger != null);

    // Emit a log record (no processor, so it won't go anywhere, but shouldn't crash)
    const status = loggerEmit(logger, 9, "INFO", "Test message", null, 0);
    try std.testing.expectEqual(OtelStatus.ok, status);
}

test "logs C API - full pipeline with processor" {
    const provider = loggerProviderCreate();
    try std.testing.expect(provider != null);
    defer loggerProviderShutdown(provider);

    // Create exporter and processor
    const exporter = logRecordExporterStdoutCreate();
    try std.testing.expect(exporter != null);

    const processor = simpleLogRecordProcessorCreate(exporter);
    try std.testing.expect(processor != null);

    // Add processor to provider
    const add_status = loggerProviderAddLogRecordProcessor(provider, processor);
    try std.testing.expectEqual(OtelStatus.ok, add_status);

    // Get logger and emit
    const logger = loggerProviderGetLogger(provider, "test-logger", null, null);
    try std.testing.expect(logger != null);

    const emit_status = loggerEmit(logger, 9, "INFO", "Test message from C API", null, 0);
    try std.testing.expectEqual(OtelStatus.ok, emit_status);
}
