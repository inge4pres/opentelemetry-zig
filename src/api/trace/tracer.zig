const std = @import("std");
const trace = @import("../trace.zig");
const context = @import("../context.zig");
const attribute = @import("../../attributes.zig");
const Attribute = @import("../../attributes.zig").Attribute;
const AttributeValue = @import("../../attributes.zig").AttributeValue;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

/// TracerProvider is the interface for creating Tracers.
/// See https://opentelemetry.io/docs/specs/otel/trace/api/#tracerprovider
pub const TracerProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        getTracerFn: *const fn (ptr: *anyopaque, scope: InstrumentationScope) anyerror!*Tracer,
        shutdownFn: *const fn (ptr: *anyopaque) void,
    };

    /// Get a new tracer by specifying its scope.
    /// If a tracer with the same scope already exists, it will be returned.
    /// See https://opentelemetry.io/docs/specs/otel/trace/api/#get-a-tracer
    pub fn getTracer(self: TracerProvider, scope: InstrumentationScope) anyerror!*Tracer {
        return self.vtable.getTracerFn(self.ptr, scope);
    }

    /// Shutdown the tracer provider and free up associated resources.
    pub fn shutdown(self: TracerProvider) void {
        return self.vtable.shutdownFn(self.ptr);
    }
};

/// Tracer is the interface for creating Spans.
/// See https://opentelemetry.io/docs/specs/otel/trace/api/#tracer
pub const Tracer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        startSpanFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, name: []const u8, options: StartOptions) anyerror!trace.Span,
        isEnabledFn: *const fn (ptr: *anyopaque) bool,
    };

    /// StartOptions contains options for starting a new span
    pub const StartOptions = struct {
        parent_context: ?context.Context = null,
        kind: trace.SpanKind = .Internal,
        attributes: ?[]const attribute.Attribute = null,
        links: ?[]const trace.Link = null,
        start_timestamp: ?u64 = null,
    };

    /// Create a new Span
    pub fn startSpan(self: Tracer, allocator: std.mem.Allocator, name: []const u8, options: StartOptions) !trace.Span {
        return self.vtable.startSpanFn(self.ptr, allocator, name, options);
    }

    /// Check if this Tracer is enabled for the given parameters
    pub fn isEnabled(self: Tracer) bool {
        return self.vtable.isEnabledFn(self.ptr);
    }
};

/// Non-recording span implementation for wrapping SpanContext
pub const NonRecordingSpan = struct {
    span_context: trace.SpanContext,

    const Self = @This();

    pub fn init(span_context: trace.SpanContext) Self {
        return Self{
            .span_context = span_context,
        };
    }

    /// Get the SpanContext for this Span
    pub fn getContext(self: Self) trace.SpanContext {
        return self.span_context;
    }

    /// Returns false as this span is not recording
    pub fn isRecording(self: Self) bool {
        _ = self;
        return false;
    }

    // All other operations are no-ops for non-recording spans
    pub fn setAttribute(self: Self, key: []const u8, value: AttributeValue) void {
        _ = self;
        _ = key;
        _ = value;
    }

    pub fn setAttributes(self: Self, attributes: []const Attribute) void {
        _ = self;
        _ = attributes;
    }

    pub fn addEvent(self: Self, name: []const u8, timestamp: ?u64, attributes: ?[]const Attribute) void {
        _ = self;
        _ = name;
        _ = timestamp;
        _ = attributes;
    }

    pub fn addLink(self: Self, span_context: trace.SpanContext, attributes: ?[]const Attribute) void {
        _ = self;
        _ = span_context;
        _ = attributes;
    }

    pub fn setStatus(self: Self, status: trace.Status) void {
        _ = self;
        _ = status;
    }

    pub fn updateName(self: Self, name: []const u8) void {
        _ = self;
        _ = name;
    }

    pub fn recordException(self: Self, exception_type: []const u8, message: []const u8, stacktrace: ?[]const u8, attributes: ?[]const Attribute) void {
        _ = self;
        _ = exception_type;
        _ = message;
        _ = stacktrace;
        _ = attributes;
    }
};
