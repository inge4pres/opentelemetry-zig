const std = @import("std");
const trace = @import("../trace.zig");
const context = @import("../context.zig");
const attribute = @import("../../attributes.zig");
const Attribute = @import("../../attributes.zig").Attribute;
const AttributeValue = @import("../../attributes.zig").AttributeValue;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const builtin = @import("builtin");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

/// TracerProvider is the entry point of the API. It provides access to Tracers.
pub const TracerProvider = struct {
    allocator: std.mem.Allocator,
    tracers: std.HashMapUnmanaged(
        InstrumentationScope,
        Tracer,
        InstrumentationScope.HashContext,
        std.hash_map.default_max_load_percentage,
    ),
    mx: std.Thread.Mutex = std.Thread.Mutex{},

    const Self = @This();

    /// Create a new custom tracer provider, using the specified allocator.
    pub fn init(alloc: std.mem.Allocator) !*Self {
        const provider = try alloc.create(Self);
        provider.* = Self{
            .allocator = alloc,
            .tracers = .empty,
        };

        return provider;
    }

    /// Adopt the default TracerProvider.
    pub fn default() !*Self {
        var gpa = switch (builtin.mode) {
            .Debug, .ReleaseSafe => debug_allocator.allocator(),
            .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
        };
        const provider = try gpa.create(Self);
        provider.* = Self{
            .allocator = gpa,
            .tracers = .empty,
        };

        return provider;
    }

    /// Delete the tracer provider and free up the memory allocated for it,
    /// as well as its owned Tracers.
    pub fn shutdown(self: *Self) void {
        self.mx.lock();

        var tracers = self.tracers.valueIterator();
        while (tracers.next()) |t| {
            t.deinit();
        }
        self.tracers.deinit(self.allocator);

        // Unlock before destroying the struct
        self.mx.unlock();
        self.allocator.destroy(self);
    }

    /// Get a new tracer by specifying its scope.
    /// If a tracer with the same scope already exists, it will be returned.
    /// See https://opentelemetry.io/docs/specs/otel/trace/api/#get-a-tracer
    pub fn getTracer(self: *Self, scope: InstrumentationScope) !*Tracer {
        self.mx.lock();
        defer self.mx.unlock();

        const t = Tracer{
            .scope = scope,
            .allocator = self.allocator,
        };

        const tracer = try self.tracers.getOrPutValue(self.allocator, scope, t);

        return tracer.value_ptr;
    }
};

/// Tracers is the creator of Spans.
pub const Tracer = struct {
    scope: InstrumentationScope,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Clean up resources
    fn deinit(self: *Self) void {
        // Cleanup the tracer attributes if they exist
        if (self.scope.attributes) |attrs| {
            self.allocator.free(attrs);
        }
    }

    /// StartOptions contains options for starting a new span
    pub const StartOptions = struct {
        parent_context: ?context.Context = null,
        kind: trace.SpanKind = .Internal,
        attributes: ?[]const attribute.Attribute = null,
        links: ?[]const trace.Link = null,
        start_timestamp: ?u64 = null,
    };

    /// Create a new Span
    pub fn startSpan(self: Self, allocator: std.mem.Allocator, name: []const u8, options: StartOptions) !trace.Span {
        // Use tracer's scope for proper tracer implementation
        _ = self.scope; // TODO: use scope for proper tracer implementation

        var parent_span_context: ?trace.SpanContext = null;
        var trace_id: trace.TraceID = undefined;

        // Determine parent context
        if (options.parent_context) |parent_ctx| {
            parent_span_context = trace.extractSpanContext(parent_ctx);
        }

        // Determine trace ID based on parent
        if (parent_span_context) |parent_sc| {
            trace_id = parent_sc.trace_id;
        } else {
            // Generate new trace ID for root span - in real implementation use proper ID generator
            var rng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))));
            var trace_bytes: [16]u8 = undefined;
            rng.random().bytes(&trace_bytes);
            // Ensure at least one byte is non-zero
            if (trace.TraceID.init(trace_bytes).isValid() == false) {
                trace_bytes[0] = 1;
            }
            trace_id = trace.TraceID.init(trace_bytes);
        }

        // Generate span ID - in real implementation use proper ID generator
        var rng2 = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp() + 1)))));
        var span_bytes: [8]u8 = undefined;
        rng2.random().bytes(&span_bytes);
        // Ensure at least one byte is non-zero
        if (trace.SpanID.init(span_bytes).isValid() == false) {
            span_bytes[0] = 1;
        }
        const span_id = trace.SpanID.init(span_bytes); // Create trace state - inherit from parent if available
        var trace_state: trace.TraceState = undefined;
        if (parent_span_context) |parent_sc| {
            trace_state = parent_sc.trace_state;
        } else {
            trace_state = trace.TraceState.init(allocator);
        }

        const span_context = trace.SpanContext.init(trace_id, span_id, trace.TraceFlags.default(), // trace_flags - TODO: implement proper sampling
            trace_state, false // is_remote - spans created locally are not remote
        );

        var span = trace.Span.init(allocator, span_context, name, options.kind);

        // Set start timestamp if provided
        if (options.start_timestamp) |timestamp| {
            span.start_time_unix_nano = timestamp;
        }

        // Set attributes if provided
        if (options.attributes) |attrs| {
            try span.setAttributes(attrs);
        }

        // Add links if provided
        if (options.links) |links| {
            for (links) |link| {
                try span.addLink(link.span_context, null);
            }
        }

        return span;
    }

    /// Check if this Tracer is enabled for the given parameters
    pub fn isEnabled(self: Self) bool {
        _ = self;
        return true; // For now, always return true
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

    pub fn end(self: Self, timestamp: ?u64) void {
        _ = self;
        _ = timestamp;
    }
};

test "TracerProvider and Tracer" {
    const tracer_provider = try TracerProvider.init(std.testing.allocator);
    defer tracer_provider.shutdown();

    const tracer = try tracer_provider.getTracer(.{ .name = "test-tracer", .version = "1.0.0" });

    try std.testing.expectEqualStrings("test-tracer", tracer.scope.name);
    try std.testing.expectEqualStrings("1.0.0", tracer.scope.version.?);
    try std.testing.expect(tracer.isEnabled());
}

test "TracerProvider default provider" {
    const tracer_provider = try TracerProvider.default();
    defer tracer_provider.shutdown();

    const tracer = try tracer_provider.getTracer(.{ .name = "default-tracer" });

    try std.testing.expectEqualStrings("default-tracer", tracer.scope.name);
    try std.testing.expect(tracer.scope.version == null);
    try std.testing.expect(tracer.isEnabled());
}

test "TracerProvider returns same tracer for same scope" {
    const tracer_provider = try TracerProvider.init(std.testing.allocator);
    defer tracer_provider.shutdown();

    const scope = InstrumentationScope{ .name = "test-tracer", .version = "1.0.0" };
    const tracer1 = try tracer_provider.getTracer(scope);
    const tracer2 = try tracer_provider.getTracer(scope);

    // Should return the same tracer instance
    try std.testing.expectEqual(tracer1, tracer2);
}

test "TracerProvider creates different tracers for different scopes" {
    const tracer_provider = try TracerProvider.init(std.testing.allocator);
    defer tracer_provider.shutdown();

    const scope1 = InstrumentationScope{ .name = "tracer1", .version = "1.0.0" };
    const scope2 = InstrumentationScope{ .name = "tracer2", .version = "1.0.0" };

    const tracer1 = try tracer_provider.getTracer(scope1);
    const tracer2 = try tracer_provider.getTracer(scope2);

    // Should return different tracer instances
    try std.testing.expect(tracer1 != tracer2);
    try std.testing.expectEqualStrings("tracer1", tracer1.scope.name);
    try std.testing.expectEqualStrings("tracer2", tracer2.scope.name);
}

test "Span creation" {
    const allocator = std.testing.allocator;

    const tracer_provider = try TracerProvider.init(std.testing.allocator);
    defer tracer_provider.shutdown();

    const tracer = try tracer_provider.getTracer(.{ .name = "test-tracer" });

    var span = try tracer.startSpan(allocator, "test-span", .{});
    defer span.deinit();

    try std.testing.expectEqualStrings("test-span", span.name);
    try std.testing.expect(span.isRecording());
    try std.testing.expectEqual(trace.SpanKind.Internal, span.kind);
}
