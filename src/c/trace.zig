//! OpenTelemetry Tracing SDK C bindings.
//!
//! This module provides C-compatible wrappers for the Zig Tracing SDK,
//! allowing C programs to use OpenTelemetry tracing instrumentation.
//!
//! ## Usage from C
//!
//! ```c
//! #include "opentelemetry.h"
//!
//! // Create a tracer provider
//! otel_tracer_provider_t* provider = otel_tracer_provider_create();
//!
//! // Add a span processor with stdout exporter
//! otel_span_exporter_t* exporter = otel_span_exporter_stdout_create();
//! otel_span_processor_t* processor = otel_simple_span_processor_create(exporter);
//! otel_tracer_provider_add_span_processor(provider, processor);
//!
//! // Get a tracer
//! otel_tracer_t* tracer = otel_tracer_provider_get_tracer(provider, "my-library", "1.0.0", NULL);
//!
//! // Start a span
//! otel_span_t* span = otel_tracer_start_span(tracer, "my-operation", NULL);
//!
//! // Add attributes and events
//! otel_span_set_attribute_string(span, "key", "value");
//! otel_span_add_event(span, "something happened", NULL, 0);
//!
//! // End the span
//! otel_span_end(span);
//!
//! // Cleanup
//! otel_tracer_provider_shutdown(provider);
//! ```

const std = @import("std");
const TracerProvider = @import("../sdk/trace/provider.zig").TracerProvider;
const Tracer = @import("../sdk/trace/provider.zig").Tracer;
const TracerImpl = @import("../api/trace/tracer.zig").TracerImpl;
const trace_api = @import("../api/trace.zig");
const Span = trace_api.Span;
const SpanKind = trace_api.SpanKind;
const Status = trace_api.Status;
const SpanContext = trace_api.SpanContext;
const TraceState = trace_api.TraceState;
const TraceFlags = trace_api.TraceFlags;
const TraceID = trace_api.TraceID;
const SpanID = trace_api.SpanID;
const Code = trace_api.Code;
const Attribute = @import("../attributes.zig").Attribute;
const AttributeValue = @import("../attributes.zig").AttributeValue;
const SpanProcessor = @import("../sdk/trace/span_processor.zig").SpanProcessor;
const SimpleProcessor = @import("../sdk/trace/span_processor.zig").SimpleProcessor;
const SpanExporter = @import("../sdk/trace/span_exporter.zig").SpanExporter;
const StdOutExporter = @import("../sdk/trace/exporters/generic.zig").StdoutExporter;
const DeprecatedStdoutExporter = @import("../sdk/trace/exporters/generic.zig").DeprecatedStdoutExporter;
const IDGenerator = @import("../sdk/trace/id_generator.zig").IDGenerator;
const RandomIDGenerator = @import("../sdk/trace/id_generator.zig").RandomIDGenerator;
const InstrumentationScope = @import("../scope.zig").InstrumentationScope;

// ============================================================================
// Error Codes (shared with metrics)
// ============================================================================

/// Error codes returned by C API functions.
pub const OtelStatus = enum(c_int) {
    ok = 0,
    error_out_of_memory = -1,
    error_invalid_argument = -2,
    error_invalid_state = -3,
    error_already_shutdown = -4,
    error_export_failed = -5,
    error_span_not_recording = -6,
    error_unknown = -99,
};

// ============================================================================
// Opaque Handle Types
// ============================================================================

/// Opaque handle to a TracerProvider.
pub const OtelTracerProvider = opaque {};

/// Opaque handle to a Tracer.
pub const OtelTracer = opaque {};

/// Opaque handle to a Span.
pub const OtelSpan = opaque {};

/// Opaque handle to a SpanProcessor.
pub const OtelSpanProcessor = opaque {};

/// Opaque handle to a SpanExporter.
pub const OtelSpanExporter = opaque {};

// ============================================================================
// Span Kind Enum
// ============================================================================

/// Span kind values for C API.
pub const OtelSpanKind = enum(c_int) {
    internal = 0,
    server = 1,
    client = 2,
    producer = 3,
    consumer = 4,

    fn toZig(self: OtelSpanKind) SpanKind {
        return switch (self) {
            .internal => .Internal,
            .server => .Server,
            .client => .Client,
            .producer => .Producer,
            .consumer => .Consumer,
        };
    }
};

// ============================================================================
// Span Status Code Enum
// ============================================================================

/// Span status code values for C API.
pub const OtelSpanStatusCode = enum(c_int) {
    unset = 0,
    ok = 1,
    @"error" = 2,

    fn toZig(self: OtelSpanStatusCode) Code {
        return switch (self) {
            .unset => .Unset,
            .ok => .Ok,
            .@"error" => .Error,
        };
    }
};

// ============================================================================
// Attribute Types (shared with metrics)
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
// Span Start Options
// ============================================================================

/// Options for starting a span.
pub const OtelSpanStartOptions = extern struct {
    /// Span kind (default: internal)
    kind: OtelSpanKind = .internal,
    /// Attributes to set on the span (can be null)
    attributes: [*c]const OtelAttribute = null,
    /// Number of attributes
    attr_count: usize = 0,
    /// Start timestamp in nanoseconds (0 means use current time)
    start_timestamp_ns: u64 = 0,
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

/// Internal storage for a span and its associated data.
const SpanWrapper = struct {
    span: Span,
    tracer: *TracerImpl,
    allocator: std.mem.Allocator,

    fn deinit(self: *SpanWrapper) void {
        self.span.deinit();
        self.allocator.destroy(self);
    }
};

// ============================================================================
// TracerProvider API
// ============================================================================

/// Create a new TracerProvider with default random ID generator.
///
/// Returns: Pointer to the TracerProvider, or null on error.
pub fn tracerProviderCreate() callconv(.c) ?*OtelTracerProvider {
    const allocator = getCAllocator();

    // Allocate the PRNG on the heap so it persists
    const prng_ptr = allocator.create(std.Random.DefaultPrng) catch return null;
    prng_ptr.* = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));

    // Create a random ID generator with the heap-allocated PRNG
    const random_generator = RandomIDGenerator.init(prng_ptr.random());
    const id_generator = IDGenerator{ .Random = random_generator };

    const provider = TracerProvider.init(allocator, id_generator) catch {
        allocator.destroy(prng_ptr);
        return null;
    };
    return @ptrCast(provider);
}

/// Shutdown the TracerProvider and release all resources.
///
/// After calling this function, the provider handle becomes invalid.
pub fn tracerProviderShutdown(provider: ?*OtelTracerProvider) callconv(.c) void {
    if (provider) |p| {
        const tp: *TracerProvider = @ptrCast(@alignCast(p));
        tp.shutdown();
    }
}

/// Get a Tracer from the TracerProvider.
///
/// Parameters:
/// - provider: The TracerProvider handle
/// - name: The name of the tracer (null-terminated string)
/// - version: Optional version string (null-terminated, can be null)
/// - schema_url: Optional schema URL (null-terminated, can be null)
///
/// Returns: Pointer to the Tracer, or null on error.
pub fn tracerProviderGetTracer(
    provider: ?*OtelTracerProvider,
    name: [*:0]const u8,
    version: ?[*:0]const u8,
    schema_url: ?[*:0]const u8,
) callconv(.c) ?*OtelTracer {
    const p = provider orelse return null;
    const tp: *TracerProvider = @ptrCast(@alignCast(p));

    const scope = InstrumentationScope{
        .name = std.mem.span(name),
        .version = if (version) |v| std.mem.span(v) else null,
        .schema_url = if (schema_url) |s| std.mem.span(s) else null,
    };

    const tracer = tp.getTracer(scope) catch return null;
    return @ptrCast(tracer);
}

/// Add a SpanProcessor to the TracerProvider.
///
/// Returns: Status code indicating success or failure.
pub fn tracerProviderAddSpanProcessor(
    provider: ?*OtelTracerProvider,
    processor: ?*OtelSpanProcessor,
) callconv(.c) OtelStatus {
    const p = provider orelse return .error_invalid_argument;
    const proc = processor orelse return .error_invalid_argument;

    const tp: *TracerProvider = @ptrCast(@alignCast(p));
    const sp: *SpanProcessor = @ptrCast(@alignCast(proc));

    tp.addSpanProcessor(sp.*) catch |err| {
        return switch (err) {
            error.OutOfMemory => .error_out_of_memory,
            error.TracerProviderShutdown => .error_already_shutdown,
        };
    };

    return .ok;
}

/// Force flush all span processors.
///
/// Returns: Status code indicating success or failure.
pub fn tracerProviderForceFlush(provider: ?*OtelTracerProvider) callconv(.c) OtelStatus {
    const p = provider orelse return .error_invalid_argument;
    const tp: *TracerProvider = @ptrCast(@alignCast(p));

    tp.forceFlush() catch |err| {
        return switch (err) {
            error.TracerProviderShutdown => .error_already_shutdown,
            else => .error_export_failed,
        };
    };

    return .ok;
}

// ============================================================================
// Tracer API
// ============================================================================

/// Start a new span.
///
/// Parameters:
/// - tracer: The Tracer handle
/// - name: The name of the span (null-terminated)
/// - options: Optional span start options (can be null for defaults)
///
/// Returns: Pointer to the Span, or null on error.
pub fn tracerStartSpan(
    tracer: ?*OtelTracer,
    name: [*:0]const u8,
    options: ?*const OtelSpanStartOptions,
) callconv(.c) ?*OtelSpan {
    const t = tracer orelse return null;
    const tr: *TracerImpl = @ptrCast(@alignCast(t));

    const allocator = getCAllocator();

    // Convert options
    var start_opts = TracerImpl.StartOptions{};

    if (options) |opts| {
        start_opts.kind = opts.kind.toZig();

        if (opts.start_timestamp_ns != 0) {
            start_opts.start_timestamp = opts.start_timestamp_ns;
        }

        // Convert attributes
        if (opts.attr_count > 0 and opts.attributes != null) {
            start_opts.attributes = convertAttributes(allocator, opts.attributes, opts.attr_count) catch return null;
        }
    }

    defer if (start_opts.attributes) |attrs| allocator.free(attrs);

    // Create span wrapper
    const wrapper = allocator.create(SpanWrapper) catch return null;

    wrapper.* = SpanWrapper{
        .span = tr.startSpan(allocator, std.mem.span(name), start_opts) catch {
            allocator.destroy(wrapper);
            return null;
        },
        .tracer = tr,
        .allocator = allocator,
    };

    return @ptrCast(wrapper);
}

/// Check if the tracer is enabled.
///
/// Returns: true if the tracer is enabled, false otherwise.
pub fn tracerIsEnabled(tracer: ?*OtelTracer) callconv(.c) bool {
    const t = tracer orelse return false;
    const tr: *TracerImpl = @ptrCast(@alignCast(t));
    return tr.isEnabled();
}

// ============================================================================
// Span API
// ============================================================================

/// End a span.
///
/// After calling this function, the span handle becomes invalid.
pub fn spanEnd(span: ?*OtelSpan) callconv(.c) void {
    if (span) |s| {
        const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));
        wrapper.tracer.endSpan(&wrapper.span);
        wrapper.deinit();
    }
}

/// End a span with a specific timestamp.
///
/// After calling this function, the span handle becomes invalid.
pub fn spanEndWithTimestamp(span: ?*OtelSpan, timestamp_ns: u64) callconv(.c) void {
    if (span) |s| {
        const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));
        wrapper.span.end(timestamp_ns);
        wrapper.deinit();
    }
}

/// Set a string attribute on the span.
pub fn spanSetAttributeString(
    span: ?*OtelSpan,
    key: [*:0]const u8,
    value: [*:0]const u8,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (!wrapper.span.isRecording()) return .error_span_not_recording;

    wrapper.span.setAttribute(std.mem.span(key), .{ .string = std.mem.span(value) }) catch return .error_out_of_memory;
    return .ok;
}

/// Set an integer attribute on the span.
pub fn spanSetAttributeInt(
    span: ?*OtelSpan,
    key: [*:0]const u8,
    value: i64,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (!wrapper.span.isRecording()) return .error_span_not_recording;

    wrapper.span.setAttribute(std.mem.span(key), .{ .int = value }) catch return .error_out_of_memory;
    return .ok;
}

/// Set a double attribute on the span.
pub fn spanSetAttributeDouble(
    span: ?*OtelSpan,
    key: [*:0]const u8,
    value: f64,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (!wrapper.span.isRecording()) return .error_span_not_recording;

    wrapper.span.setAttribute(std.mem.span(key), .{ .double = value }) catch return .error_out_of_memory;
    return .ok;
}

/// Set a boolean attribute on the span.
pub fn spanSetAttributeBool(
    span: ?*OtelSpan,
    key: [*:0]const u8,
    value: bool,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (!wrapper.span.isRecording()) return .error_span_not_recording;

    wrapper.span.setAttribute(std.mem.span(key), .{ .bool = value }) catch return .error_out_of_memory;
    return .ok;
}

/// Add an event to the span.
///
/// Parameters:
/// - span: The Span handle
/// - name: Event name (null-terminated)
/// - attributes: Array of attributes (can be null)
/// - attr_count: Number of attributes
pub fn spanAddEvent(
    span: ?*OtelSpan,
    name: [*:0]const u8,
    attributes: [*c]const OtelAttribute,
    attr_count: usize,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (!wrapper.span.isRecording()) return .error_span_not_recording;

    const allocator = getCAllocator();
    const attrs = convertAttributes(allocator, attributes, attr_count) catch return .error_out_of_memory;
    defer if (attrs) |a| allocator.free(a);

    wrapper.span.addEvent(std.mem.span(name), null, attrs) catch return .error_out_of_memory;
    return .ok;
}

/// Add an event with a specific timestamp.
pub fn spanAddEventWithTimestamp(
    span: ?*OtelSpan,
    name: [*:0]const u8,
    timestamp_ns: u64,
    attributes: [*c]const OtelAttribute,
    attr_count: usize,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (!wrapper.span.isRecording()) return .error_span_not_recording;

    const allocator = getCAllocator();
    const attrs = convertAttributes(allocator, attributes, attr_count) catch return .error_out_of_memory;
    defer if (attrs) |a| allocator.free(a);

    wrapper.span.addEvent(std.mem.span(name), timestamp_ns, attrs) catch return .error_out_of_memory;
    return .ok;
}

/// Set the status of the span.
pub fn spanSetStatus(
    span: ?*OtelSpan,
    code: OtelSpanStatusCode,
    description: ?[*:0]const u8,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (!wrapper.span.isRecording()) return .error_span_not_recording;

    const desc = if (description) |d| std.mem.span(d) else "";
    wrapper.span.setStatus(Status{
        .code = code.toZig(),
        .description = desc,
    });
    return .ok;
}

/// Update the name of the span.
pub fn spanUpdateName(
    span: ?*OtelSpan,
    name: [*:0]const u8,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (!wrapper.span.isRecording()) return .error_span_not_recording;

    wrapper.span.updateName(std.mem.span(name));
    return .ok;
}

/// Record an exception on the span.
pub fn spanRecordException(
    span: ?*OtelSpan,
    exception_type: [*:0]const u8,
    message: [*:0]const u8,
    stacktrace: ?[*:0]const u8,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (!wrapper.span.isRecording()) return .error_span_not_recording;

    const st = if (stacktrace) |st| std.mem.span(st) else null;
    wrapper.span.recordException(
        std.mem.span(exception_type),
        std.mem.span(message),
        st,
        null,
    ) catch return .error_out_of_memory;
    return .ok;
}

/// Check if the span is recording.
pub fn spanIsRecording(span: ?*OtelSpan) callconv(.c) bool {
    const s = span orelse return false;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));
    return wrapper.span.isRecording();
}

/// Get the trace ID as a hex string.
/// The buffer must be at least 33 bytes (32 hex chars + null terminator).
pub fn spanGetTraceIdHex(
    span: ?*OtelSpan,
    buffer: [*]u8,
    buffer_size: usize,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (buffer_size < 33) return .error_invalid_argument;

    var hex_buf: [32]u8 = undefined;
    const hex = wrapper.span.span_context.trace_id.toHex(&hex_buf);
    @memcpy(buffer[0..32], hex);
    buffer[32] = 0;
    return .ok;
}

/// Get the span ID as a hex string.
/// The buffer must be at least 17 bytes (16 hex chars + null terminator).
pub fn spanGetSpanIdHex(
    span: ?*OtelSpan,
    buffer: [*]u8,
    buffer_size: usize,
) callconv(.c) OtelStatus {
    const s = span orelse return .error_invalid_argument;
    const wrapper: *SpanWrapper = @ptrCast(@alignCast(s));

    if (buffer_size < 17) return .error_invalid_argument;

    var hex_buf: [16]u8 = undefined;
    const hex = wrapper.span.span_context.span_id.toHex(&hex_buf);
    @memcpy(buffer[0..16], hex);
    buffer[16] = 0;
    return .ok;
}

// ============================================================================
// SpanExporter API
// ============================================================================

/// Create a stdout SpanExporter for debugging.
///
/// Returns: Pointer to the SpanExporter, or null on error.
pub fn spanExporterStdoutCreate() callconv(.c) ?*OtelSpanExporter {
    const allocator = getCAllocator();

    // Allocate the exporter on the heap
    const exporter_ptr = allocator.create(DeprecatedStdoutExporter) catch return null;
    exporter_ptr.* = DeprecatedStdoutExporter.init(std.fs.File.stdout().deprecatedWriter());

    // Allocate the SpanExporter interface on the heap
    const span_exporter_ptr = allocator.create(SpanExporter) catch {
        allocator.destroy(exporter_ptr);
        return null;
    };
    span_exporter_ptr.* = exporter_ptr.asSpanExporter();

    return @ptrCast(span_exporter_ptr);
}

// ============================================================================
// SpanProcessor API
// ============================================================================

/// Create a SimpleProcessor that exports spans immediately.
///
/// Parameters:
/// - exporter: The SpanExporter handle
///
/// Returns: Pointer to the SpanProcessor, or null on error.
pub fn simpleSpanProcessorCreate(exporter: ?*OtelSpanExporter) callconv(.c) ?*OtelSpanProcessor {
    const e = exporter orelse return null;
    const allocator = getCAllocator();

    const exp: *SpanExporter = @ptrCast(@alignCast(e));

    const storage = allocator.create(SimpleProcessor) catch return null;
    storage.* = SimpleProcessor.init(allocator, exp.*);

    const processor_ptr = allocator.create(SpanProcessor) catch {
        allocator.destroy(storage);
        return null;
    };
    processor_ptr.* = storage.asSpanProcessor();

    return @ptrCast(processor_ptr);
}

// ============================================================================
// C Export Declarations
// ============================================================================

comptime {
    // TracerProvider exports
    @export(&tracerProviderCreate, .{ .name = "otel_tracer_provider_create" });
    @export(&tracerProviderShutdown, .{ .name = "otel_tracer_provider_shutdown" });
    @export(&tracerProviderGetTracer, .{ .name = "otel_tracer_provider_get_tracer" });
    @export(&tracerProviderAddSpanProcessor, .{ .name = "otel_tracer_provider_add_span_processor" });
    @export(&tracerProviderForceFlush, .{ .name = "otel_tracer_provider_force_flush" });

    // Tracer exports
    @export(&tracerStartSpan, .{ .name = "otel_tracer_start_span" });
    @export(&tracerIsEnabled, .{ .name = "otel_tracer_is_enabled" });

    // Span exports
    @export(&spanEnd, .{ .name = "otel_span_end" });
    @export(&spanEndWithTimestamp, .{ .name = "otel_span_end_with_timestamp" });
    @export(&spanSetAttributeString, .{ .name = "otel_span_set_attribute_string" });
    @export(&spanSetAttributeInt, .{ .name = "otel_span_set_attribute_int" });
    @export(&spanSetAttributeDouble, .{ .name = "otel_span_set_attribute_double" });
    @export(&spanSetAttributeBool, .{ .name = "otel_span_set_attribute_bool" });
    @export(&spanAddEvent, .{ .name = "otel_span_add_event" });
    @export(&spanAddEventWithTimestamp, .{ .name = "otel_span_add_event_with_timestamp" });
    @export(&spanSetStatus, .{ .name = "otel_span_set_status" });
    @export(&spanUpdateName, .{ .name = "otel_span_update_name" });
    @export(&spanRecordException, .{ .name = "otel_span_record_exception" });
    @export(&spanIsRecording, .{ .name = "otel_span_is_recording" });
    @export(&spanGetTraceIdHex, .{ .name = "otel_span_get_trace_id_hex" });
    @export(&spanGetSpanIdHex, .{ .name = "otel_span_get_span_id_hex" });

    // SpanExporter exports
    @export(&spanExporterStdoutCreate, .{ .name = "otel_span_exporter_stdout_create" });

    // SpanProcessor exports
    @export(&simpleSpanProcessorCreate, .{ .name = "otel_simple_span_processor_create" });
}

// ============================================================================
// Tests
// ============================================================================

test "trace C API - create tracer provider" {
    const provider = tracerProviderCreate();
    try std.testing.expect(provider != null);
    defer tracerProviderShutdown(provider);
}

test "trace C API - get tracer" {
    const provider = tracerProviderCreate();
    try std.testing.expect(provider != null);
    defer tracerProviderShutdown(provider);

    const tracer = tracerProviderGetTracer(provider, "test-tracer", "1.0.0", null);
    try std.testing.expect(tracer != null);

    try std.testing.expect(tracerIsEnabled(tracer));
}

test "trace C API - start and end span" {
    const provider = tracerProviderCreate();
    try std.testing.expect(provider != null);
    defer tracerProviderShutdown(provider);

    const tracer = tracerProviderGetTracer(provider, "test-tracer", null, null);
    try std.testing.expect(tracer != null);

    const span = tracerStartSpan(tracer, "test-span", null);
    try std.testing.expect(span != null);

    try std.testing.expect(spanIsRecording(span));

    // Set some attributes
    try std.testing.expectEqual(OtelStatus.ok, spanSetAttributeString(span, "key1", "value1"));
    try std.testing.expectEqual(OtelStatus.ok, spanSetAttributeInt(span, "key2", 42));

    // Add an event
    try std.testing.expectEqual(OtelStatus.ok, spanAddEvent(span, "test-event", null, 0));

    // Set status
    try std.testing.expectEqual(OtelStatus.ok, spanSetStatus(span, .ok, null));

    // End the span
    spanEnd(span);
}

test "trace C API - span with options" {
    const provider = tracerProviderCreate();
    try std.testing.expect(provider != null);
    defer tracerProviderShutdown(provider);

    const tracer = tracerProviderGetTracer(provider, "test-tracer", null, null);
    try std.testing.expect(tracer != null);

    var options = OtelSpanStartOptions{
        .kind = .server,
    };

    const span = tracerStartSpan(tracer, "server-span", &options);
    try std.testing.expect(span != null);
    defer spanEnd(span);

    try std.testing.expect(spanIsRecording(span));
}

test "trace C API - get trace and span IDs" {
    const provider = tracerProviderCreate();
    try std.testing.expect(provider != null);
    defer tracerProviderShutdown(provider);

    const tracer = tracerProviderGetTracer(provider, "test-tracer", null, null);
    try std.testing.expect(tracer != null);

    const span = tracerStartSpan(tracer, "test-span", null);
    try std.testing.expect(span != null);
    defer spanEnd(span);

    var trace_id_buf: [33]u8 = undefined;
    var span_id_buf: [17]u8 = undefined;

    try std.testing.expectEqual(OtelStatus.ok, spanGetTraceIdHex(span, &trace_id_buf, 33));
    try std.testing.expectEqual(OtelStatus.ok, spanGetSpanIdHex(span, &span_id_buf, 17));

    // Verify the IDs are valid hex strings (not all zeros typically)
    try std.testing.expect(trace_id_buf[0] != 0);
    try std.testing.expect(span_id_buf[0] != 0);
}
