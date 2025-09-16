const std = @import("std");
const context = @import("context.zig");
const attribute = @import("../attributes.zig");

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

// Context keys for SpanContext serialization - generated at compile time using metaprogramming
const SpanContextKeys = blk: {
    const fields = std.meta.fields(SpanContext);
    var keys: [fields.len]context.ContextKey = undefined;
    for (fields, 0..) |field, i| {
        // Use compile-time string concatenation to create unique key names
        const key_name = "opentelemetry.span_context." ++ field.name;
        keys[i] = context.ContextKey{
            .id = i, // Use field index as unique ID
            .name = key_name,
        };
    }
    break :blk keys;
};

/// Get the context key for a specific SpanContext field at compile time
fn getSpanContextKey(comptime field_name: []const u8) context.ContextKey {
    const fields = std.meta.fields(SpanContext);
    inline for (fields, 0..) |field, i| {
        if (comptime std.mem.eql(u8, field.name, field_name)) {
            return SpanContextKeys[i];
        }
    }
    @compileError("Unknown SpanContext field: " ++ field_name);
}

/// Serialize a field value to AttributeValue based on its type
fn serializeField(allocator: std.mem.Allocator, field_value: anytype) !attribute.AttributeValue {
    const T = @TypeOf(field_value);

    switch (T) {
        TraceID => {
            var buf: [32]u8 = undefined;
            const hex = field_value.toHex(&buf);
            return .{ .string = try allocator.dupe(u8, hex) };
        },
        SpanID => {
            var buf: [16]u8 = undefined;
            const hex = field_value.toHex(&buf);
            return .{ .string = try allocator.dupe(u8, hex) };
        },
        TraceFlags => {
            return .{ .int = field_value.value };
        },
        TraceState => {
            var trace_state_buf = std.ArrayList(u8).init(allocator);
            defer trace_state_buf.deinit();

            var iterator = field_value.entries.iterator();
            var first = true;
            while (iterator.next()) |entry| {
                if (!first) {
                    try trace_state_buf.append(',');
                }
                try trace_state_buf.appendSlice(entry.key_ptr.*);
                try trace_state_buf.append('=');
                try trace_state_buf.appendSlice(entry.value_ptr.*);
                first = false;
            }

            return .{ .string = try allocator.dupe(u8, trace_state_buf.items) };
        },
        bool => {
            return .{ .bool = field_value };
        },
        else => @compileError("Unsupported field type for SpanContext serialization: " ++ @typeName(T)),
    }
}

/// Deserialize a field value from AttributeValue based on the expected type
fn deserializeField(allocator: std.mem.Allocator, comptime T: type, attr_value: attribute.AttributeValue) ?T {
    switch (T) {
        TraceID => {
            if (attr_value != .string) return null;
            return TraceID.fromHex(attr_value.string) catch null;
        },
        SpanID => {
            if (attr_value != .string) return null;
            return SpanID.fromHex(attr_value.string) catch null;
        },
        TraceFlags => {
            if (attr_value != .int) return null;
            return TraceFlags.init(@intCast(attr_value.int));
        },
        TraceState => {
            if (attr_value != .string) return null;

            var trace_state = TraceState.init(allocator);
            errdefer trace_state.deinit();

            if (attr_value.string.len > 0) {
                var entries = std.mem.splitScalar(u8, attr_value.string, ',');
                while (entries.next()) |entry| {
                    var kv = std.mem.splitScalar(u8, entry, '=');
                    const key = kv.next() orelse continue;
                    const value = kv.next() orelse continue;

                    // Handle intermediate TraceState allocations properly
                    const new_state = trace_state.insert(allocator, key, value) catch continue;
                    trace_state.deinit();
                    trace_state = new_state;
                }
            }

            return trace_state;
        },
        bool => {
            if (attr_value != .bool) return null;
            return attr_value.bool;
        },
        else => @compileError("Unsupported field type for SpanContext deserialization: " ++ @typeName(T)),
    }
}

/// Serialize a SpanContext to a Context by storing each field as a separate context entry.
/// Returns a new Context containing all SpanContext fields.
///
/// NOTE: This function allocates memory for string serialization that is stored in the Context.
/// Use `freeSerializedSpanContext()` to properly clean up the allocated memory before calling ctx.deinit().
pub fn serializeSpanContext(allocator: std.mem.Allocator, span_context: SpanContext) !context.Context {
    var ctx = context.Context.init();

    // Use metaprogramming to serialize all fields
    const fields = std.meta.fields(SpanContext);
    inline for (fields) |field| {
        const field_value = @field(span_context, field.name);
        const attr_value = try serializeField(allocator, field_value);
        const key = getSpanContextKey(field.name);

        // Handle intermediate Context allocations properly
        const new_ctx = try ctx.setValue(allocator, key, attr_value);
        ctx.deinit();
        ctx = new_ctx;
    }

    return ctx;
}

/// Free all allocated strings in a serialized SpanContext before calling deinit().
/// This function must be called on contexts created by serializeSpanContext() to prevent memory leaks.
pub fn freeSerializedSpanContext(allocator: std.mem.Allocator, ctx: context.Context) void {
    const fields = std.meta.fields(SpanContext);
    inline for (fields) |field| {
        const key = getSpanContextKey(field.name);
        if (ctx.getValue(key)) |attr_value| {
            switch (attr_value) {
                .string => |str| {
                    // Free the allocated string
                    allocator.free(str);
                },
                else => {},
            }
        }
    }
}

/// Deserialize a SpanContext from a Context by reading each field from separate context entries.
/// Returns null if any required fields are missing or invalid.
pub fn deserializeSpanContext(ctx: context.Context) ?SpanContext {
    const allocator = ctx.allocator orelse return null;

    // Use metaprogramming to deserialize all fields
    const fields = std.meta.fields(SpanContext);
    var field_values: [fields.len]?attribute.AttributeValue = undefined;

    // Read all field values from context
    inline for (fields, 0..) |field, i| {
        const key = getSpanContextKey(field.name);
        field_values[i] = ctx.getValue(key);
        if (field_values[i] == null) return null;
    }

    // Deserialize all fields
    var result: SpanContext = undefined;
    inline for (fields, 0..) |field, i| {
        const field_value = deserializeField(allocator, field.type, field_values[i].?) orelse return null;
        @field(result, field.name) = field_value;
    }

    return result;
}

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
    return deserializeSpanContext(ctx);
}

/// Combine a SpanContext with a Context instance, creating a new Context instance
pub fn insertSpanContext(allocator: std.mem.Allocator, span_context: SpanContext) !context.Context {
    return serializeSpanContext(allocator, span_context);
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
    const new_context = try insertSpanContext(allocator, span_context);
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

test "SpanContext serialization/deserialization with metaprogramming" {
    const allocator = std.testing.allocator;

    // Create a SpanContext with trace state
    const trace_id = TraceID.init([16]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    const span_id = SpanID.init([8]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    const trace_flags = TraceFlags.init(1);

    var trace_state = TraceState.init(allocator);
    defer trace_state.deinit();

    // Handle intermediate TraceState allocations properly
    const temp_state1 = try trace_state.insert(allocator, "key1", "value1");
    trace_state.deinit(); // Free the original empty state
    trace_state = temp_state1;

    const temp_state2 = try trace_state.insert(allocator, "key2", "value2");
    trace_state.deinit(); // Free the first state
    trace_state = temp_state2;

    const original_span_context = SpanContext.init(trace_id, span_id, trace_flags, trace_state, true);

    // Serialize SpanContext to Context
    var ctx = try serializeSpanContext(allocator, original_span_context);
    defer {
        freeSerializedSpanContext(allocator, ctx);
        ctx.deinit();
    }

    // Deserialize back to SpanContext
    const deserialized_span_context = deserializeSpanContext(ctx) orelse {
        try std.testing.expect(false); // Should not fail
        return;
    };
    defer {
        var mut_state = deserialized_span_context.trace_state;
        mut_state.deinit();
    }

    // Verify all fields are correctly preserved
    try std.testing.expectEqual(original_span_context.trace_id.value, deserialized_span_context.trace_id.value);
    try std.testing.expectEqual(original_span_context.span_id.value, deserialized_span_context.span_id.value);
    try std.testing.expectEqual(original_span_context.trace_flags.value, deserialized_span_context.trace_flags.value);
    try std.testing.expectEqual(original_span_context.is_remote, deserialized_span_context.is_remote);

    // Verify trace state entries
    try std.testing.expectEqual(@as(usize, 2), deserialized_span_context.trace_state.entries.count());
    try std.testing.expectEqualStrings("value1", deserialized_span_context.trace_state.get("key1").?);
    try std.testing.expectEqualStrings("value2", deserialized_span_context.trace_state.get("key2").?);
}

test "SpanContext serialization with empty trace state" {
    const allocator = std.testing.allocator;

    // Create a SpanContext with empty trace state
    const trace_id = TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const span_id = SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const trace_flags = TraceFlags.init(0);

    var empty_trace_state = TraceState.init(allocator);
    defer empty_trace_state.deinit();

    const original_span_context = SpanContext.init(trace_id, span_id, trace_flags, empty_trace_state, false);

    // Serialize to Context
    var ctx = try serializeSpanContext(allocator, original_span_context);
    defer {
        freeSerializedSpanContext(allocator, ctx);
        ctx.deinit();
    }

    // Deserialize back to SpanContext
    const deserialized_span_context = deserializeSpanContext(ctx) orelse {
        try std.testing.expect(false); // Should not fail
        return;
    };
    defer {
        var mut_state = deserialized_span_context.trace_state;
        mut_state.deinit();
    }

    // Verify all fields are correctly preserved
    try std.testing.expectEqual(original_span_context.trace_id.value, deserialized_span_context.trace_id.value);
    try std.testing.expectEqual(original_span_context.span_id.value, deserialized_span_context.span_id.value);
    try std.testing.expectEqual(original_span_context.trace_flags.value, deserialized_span_context.trace_flags.value);
    try std.testing.expectEqual(original_span_context.is_remote, deserialized_span_context.is_remote);

    // Verify trace state is empty
    try std.testing.expectEqual(@as(usize, 0), deserialized_span_context.trace_state.entries.count());
}

test "SpanContext deserialization failure with missing fields" {
    const allocator = std.testing.allocator;

    // Create a context with only some SpanContext fields using a duplicated string
    var ctx = context.Context.init();
    const trace_id_str = try allocator.dupe(u8, "0123456789abcdef0123456789abcdef");
    defer allocator.free(trace_id_str);
    ctx = try ctx.setValue(allocator, getSpanContextKey("trace_id"), .{ .string = trace_id_str });
    // Intentionally missing other fields
    defer ctx.deinit();

    // Deserialization should fail due to missing fields
    const result = deserializeSpanContext(ctx);
    try std.testing.expect(result == null);
}

test "SpanContext deserialization failure with invalid field types" {
    const allocator = std.testing.allocator;

    // Create a context with invalid field types
    var ctx = context.Context.init();

    // Handle intermediate Context allocations properly
    var temp_ctx = try ctx.setValue(allocator, getSpanContextKey("trace_id"), .{ .int = 123 }); // Wrong type, should be string
    ctx.deinit();
    ctx = temp_ctx;

    const span_id_str = try allocator.dupe(u8, "0123456789abcdef");
    defer allocator.free(span_id_str);
    temp_ctx = try ctx.setValue(allocator, getSpanContextKey("span_id"), .{ .string = span_id_str });
    ctx.deinit();
    ctx = temp_ctx;

    temp_ctx = try ctx.setValue(allocator, getSpanContextKey("trace_flags"), .{ .int = 0 });
    ctx.deinit();
    ctx = temp_ctx;

    const trace_state_str = try allocator.dupe(u8, "");
    defer allocator.free(trace_state_str);
    temp_ctx = try ctx.setValue(allocator, getSpanContextKey("trace_state"), .{ .string = trace_state_str });
    ctx.deinit();
    ctx = temp_ctx;

    temp_ctx = try ctx.setValue(allocator, getSpanContextKey("is_remote"), .{ .bool = false });
    ctx.deinit();
    ctx = temp_ctx;

    defer ctx.deinit();

    // Deserialization should fail due to invalid trace_id type
    const result = deserializeSpanContext(ctx);
    try std.testing.expect(result == null);
}

test "SpanContext context key generation" {
    // Test that compile-time key generation works correctly
    const trace_id_key = getSpanContextKey("trace_id");
    const span_id_key = getSpanContextKey("span_id");
    const trace_flags_key = getSpanContextKey("trace_flags");
    const trace_state_key = getSpanContextKey("trace_state");
    const is_remote_key = getSpanContextKey("is_remote");

    // Keys should be unique
    try std.testing.expect(trace_id_key.id != span_id_key.id);
    try std.testing.expect(trace_id_key.id != trace_flags_key.id);
    try std.testing.expect(trace_id_key.id != trace_state_key.id);
    try std.testing.expect(trace_id_key.id != is_remote_key.id);
    try std.testing.expect(span_id_key.id != trace_flags_key.id);
    try std.testing.expect(span_id_key.id != trace_state_key.id);
    try std.testing.expect(span_id_key.id != is_remote_key.id);
    try std.testing.expect(trace_flags_key.id != trace_state_key.id);
    try std.testing.expect(trace_flags_key.id != is_remote_key.id);
    try std.testing.expect(trace_state_key.id != is_remote_key.id);

    // Keys should have correct names
    try std.testing.expectEqualStrings("opentelemetry.span_context.trace_id", trace_id_key.name);
    try std.testing.expectEqualStrings("opentelemetry.span_context.span_id", span_id_key.name);
    try std.testing.expectEqualStrings("opentelemetry.span_context.trace_flags", trace_flags_key.name);
    try std.testing.expectEqualStrings("opentelemetry.span_context.trace_state", trace_state_key.name);
    try std.testing.expectEqualStrings("opentelemetry.span_context.is_remote", is_remote_key.name);
}

test "SpanContext round-trip serialization preserves span context validity" {
    const allocator = std.testing.allocator;

    // Create valid SpanContext
    const trace_id = TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const span_id = SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const trace_flags = TraceFlags.init(1);

    var trace_state = TraceState.init(allocator);
    defer trace_state.deinit();

    const original_span_context = SpanContext.init(trace_id, span_id, trace_flags, trace_state, true);
    try std.testing.expect(original_span_context.isValid());

    // Round-trip serialization
    var ctx = try serializeSpanContext(allocator, original_span_context);
    defer {
        freeSerializedSpanContext(allocator, ctx);
        ctx.deinit();
    }

    const deserialized_span_context = deserializeSpanContext(ctx) orelse {
        try std.testing.expect(false); // Should not fail
        return;
    };
    defer {
        var mut_state = deserialized_span_context.trace_state;
        mut_state.deinit();
    }

    // Deserialized context should still be valid
    try std.testing.expect(deserialized_span_context.isValid());
    try std.testing.expectEqual(original_span_context.isRemote(), deserialized_span_context.isRemote());
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
