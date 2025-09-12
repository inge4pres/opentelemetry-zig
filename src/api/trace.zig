const std = @import("std");
const context = @import("context.zig");
const attribute = @import("../attributes.zig");

/// Time-related data types
/// Timestamp represents time elapsed since the Unix epoch in nanoseconds.
/// The minimal precision is milliseconds, maximal precision is nanoseconds.
pub const Timestamp = u64;

/// Duration represents elapsed time between two events in nanoseconds.
/// The minimal precision is milliseconds, maximal precision is nanoseconds.
pub const Duration = u64;

/// Convert nanoseconds to milliseconds (minimal precision requirement)
pub fn nanoToMilli(nanos: u64) u64 {
    return nanos / std.time.ns_per_ms;
}

/// Convert milliseconds to nanoseconds
pub fn milliToNano(millis: u64) u64 {
    return millis * std.time.ns_per_ms;
}

pub const Tracer = @import("trace/tracer.zig").Tracer;
pub const TracerConfig = @import("trace/config.zig").TracerConfig;
pub const TracerProvider = @import("trace/tracer.zig").TracerProvider;

const span = @import("trace/span.zig");
pub const Span = span.Span;
pub const SpanKind = span.SpanKind;
pub const Status = span.Status;
pub const SpanContext = span.SpanContext;
pub const TraceState = span.TraceState;
pub const Event = @import("trace/span.zig").Span.Event;
pub const Code = @import("trace/code.zig").Code;
pub const Link = @import("trace/span.zig").Span.Link;
pub const TraceFlags = @import("trace/trace_flags.zig").TraceFlags;

// TODO: Context keys for span propagation - currently disabled due to comptime issues
// const SpanContextKey = context.Key("opentelemetry.span_context");

// Global TracerProvider management
var global_tracer_provider: ?*TracerProvider = null;
var global_tracer_provider_mutex: std.Thread.Mutex = .{};

/// Set the global TracerProvider
pub fn setGlobalTracerProvider(provider: *TracerProvider) void {
    global_tracer_provider_mutex.lock();
    defer global_tracer_provider_mutex.unlock();
    global_tracer_provider = provider;
}

/// Get the global TracerProvider. Returns a default provider if none has been set.
pub fn getGlobalTracerProvider() *TracerProvider {
    global_tracer_provider_mutex.lock();
    defer global_tracer_provider_mutex.unlock();

    if (global_tracer_provider) |provider| {
        return provider;
    }

    // Return a default provider - in a real implementation, this would be a no-op provider
    // For now, we'll create a basic one (this is not ideal for production)
    global_tracer_provider = TracerProvider.default() catch {
        // In case of failure, we could return a no-op provider
        // For now, we'll panic as this indicates a serious issue
        std.debug.panic("Failed to create default TracerProvider");
    };
    return global_tracer_provider.?;
}

// Context keys for span propagation

/// Extract the SpanContext from a Context instance
pub fn extractSpanContext(ctx: context.Context) ?SpanContext {
    // For now, we don't have a working context key system, so we'll return null
    // In a proper implementation, this would use a proper context key
    _ = ctx;
    return null;
}

/// Combine a SpanContext with a Context instance, creating a new Context instance
pub fn insertSpanContext(allocator: std.mem.Allocator, ctx: context.Context, span_context: SpanContext) !context.Context {
    // For now, we don't have a working context key system, so we'll return the original context
    // In a proper implementation, this would store the SpanContext in the context
    _ = allocator;
    _ = span_context;
    return ctx;
}

/// Get the currently active span from the implicit context
pub fn getCurrentSpan() ?Span {
    const current_context = context.getCurrentContext();
    if (extractSpanContext(current_context)) |span_context| {
        // Create a non-recording span wrapper for the SpanContext
        return wrapSpanContext(span_context);
    }
    return null;
}

/// Wrap a SpanContext in a Span interface.
/// This creates a non-recording span that exposes the SpanContext.
pub fn wrapSpanContext(span_context: SpanContext) Span {
    return Span.fromSpanContext(span_context);
}

/// Set the currently active span into a new context, and make that the implicit context
pub fn setCurrentSpan(allocator: std.mem.Allocator, active_span: Span) !context.Token {
    const span_context = active_span.getContext();
    const current_context = context.getCurrentContext();
    const new_context = try insertSpanContext(allocator, current_context, span_context);
    return try context.attachContext(new_context);
}

test {
    _ = @import("trace/code.zig");
    _ = @import("trace/config.zig");
    _ = @import("trace/link.zig");
    _ = @import("trace/span.zig");
    _ = @import("trace/tracer.zig");
    _ = @import("trace/trace_flags.zig");
}

pub const TraceID = struct {
    value: [16]u8,

    const Self = @This();

    pub fn init(value: [16]u8) Self {
        return .{
            .value = value,
        };
    }

    pub fn zero() Self {
        return init([16]u8{
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        });
    }

    pub fn isValid(self: Self) bool {
        for (self.value) |item| {
            if (item != 0) {
                return true;
            }
        }

        return false;
    }

    /// Returns the lowercase hex encoded TraceId (32-hex-character lowercase string)
    pub fn toHex(self: Self, buf: *[32]u8) []const u8 {
        _ = std.fmt.bufPrint(buf, "{x:0>32}", .{std.mem.readInt(u128, &self.value, .big)}) catch unreachable;
        return buf;
    }

    /// Returns the binary representation of the TraceId (16-byte array)
    pub fn toBinary(self: Self) [16]u8 {
        return self.value;
    }

    /// Create TraceID from hex string
    pub fn fromHex(hex_string: []const u8) !Self {
        if (hex_string.len != 32) return error.InvalidHexLength;

        var value: [16]u8 = undefined;
        for (0..16) |i| {
            value[i] = try std.fmt.parseInt(u8, hex_string[i * 2 .. i * 2 + 2], 16);
        }
        return Self.init(value);
    }
};

pub const SpanID = struct {
    value: [8]u8,

    const Self = @This();

    pub fn init(value: [8]u8) Self {
        return .{
            .value = value,
        };
    }

    pub fn zero() Self {
        return init([8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    }

    pub fn isValid(self: Self) bool {
        for (self.value) |item| {
            if (item != 0) {
                return true;
            }
        }

        return false;
    }

    /// Returns the lowercase hex encoded SpanId (16-hex-character lowercase string)
    pub fn toHex(self: Self, buf: *[16]u8) []const u8 {
        _ = std.fmt.bufPrint(buf, "{x:0>16}", .{std.mem.readInt(u64, &self.value, .big)}) catch unreachable;
        return buf;
    }

    /// Returns the binary representation of the SpanId (8-byte array)
    pub fn toBinary(self: Self) [8]u8 {
        return self.value;
    }

    /// Create SpanID from hex string
    pub fn fromHex(hex_string: []const u8) !Self {
        if (hex_string.len != 16) return error.InvalidHexLength;

        var value: [8]u8 = undefined;
        for (0..8) |i| {
            value[i] = try std.fmt.parseInt(u8, hex_string[i * 2 .. i * 2 + 2], 16);
        }
        return Self.init(value);
    }
};

test "TraceID isValid" {
    try std.testing.expect(TraceID.init([16]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).isValid());
    try std.testing.expect(!TraceID.init([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).isValid());
}

test "TraceID hex conversion" {
    const trace_id = TraceID.init([16]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    var buf: [32]u8 = undefined;
    const hex = trace_id.toHex(&buf);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", hex);

    // Test round-trip conversion
    const parsed = try TraceID.fromHex(hex);
    try std.testing.expectEqual(trace_id.value, parsed.value);
}

test "TraceID binary conversion" {
    const trace_id = TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const binary = trace_id.toBinary();
    try std.testing.expectEqual(trace_id.value, binary);
}

test "SpanID isValid" {
    try std.testing.expect(SpanID.init([8]u8{
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    }).isValid());
    try std.testing.expect(!SpanID.init([8]u8{
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    }).isValid());
}

test "SpanID hex conversion" {
    const span_id = SpanID.init([8]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    var buf: [16]u8 = undefined;
    const hex = span_id.toHex(&buf);
    try std.testing.expectEqualStrings("0123456789abcdef", hex);

    // Test round-trip conversion
    const parsed = try SpanID.fromHex(hex);
    try std.testing.expectEqual(span_id.value, parsed.value);
}

test "SpanID binary conversion" {
    const span_id = SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const binary = span_id.toBinary();
    try std.testing.expectEqual(span_id.value, binary);
}

test "Time conversion utilities" {
    const nanos: u64 = 1_000_000_000; // 1 second in nanoseconds
    const millis = nanoToMilli(nanos);
    try std.testing.expectEqual(@as(u64, 1000), millis); // 1000 milliseconds

    const back_to_nanos = milliToNano(millis);
    try std.testing.expectEqual(nanos, back_to_nanos);
}
