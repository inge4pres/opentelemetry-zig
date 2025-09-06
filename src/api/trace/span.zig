const std = @import("std");

const attribute = @import("../../attributes.zig");
const trace = @import("../trace.zig");
const context = @import("../context.zig");

/// SpanContext represents the portion of a Span which must be serialized and propagated.
/// SpanContexts are immutable.
pub const SpanContext = struct {
    trace_id: trace.TraceID,
    span_id: trace.SpanID,
    trace_flags: trace.TraceFlags,
    trace_state: TraceState,
    is_remote: bool,

    const Self = @This();

    pub fn init(trace_id: trace.TraceID, span_id: trace.SpanID, trace_flags: trace.TraceFlags, trace_state: TraceState, is_remote: bool) Self {
        return Self{
            .trace_id = trace_id,
            .span_id = span_id,
            .trace_flags = trace_flags,
            .trace_state = trace_state,
            .is_remote = is_remote,
        };
    }

    /// Returns true if the SpanContext has a non-zero TraceID and a non-zero SpanID
    pub fn isValid(self: Self) bool {
        return self.trace_id.isValid() and self.span_id.isValid();
    }

    /// Returns true if the SpanContext was propagated from a remote parent
    pub fn isRemote(self: Self) bool {
        return self.is_remote;
    }

    /// Returns the trace ID
    pub fn getTraceId(self: Self) trace.TraceID {
        return self.trace_id;
    }

    /// Returns the span ID
    pub fn getSpanId(self: Self) trace.SpanID {
        return self.span_id;
    }

    /// Returns the trace flags
    pub fn getTraceFlags(self: Self) trace.TraceFlags {
        return self.trace_flags;
    }

    /// Returns the trace state
    pub fn getTraceState(self: Self) TraceState {
        return self.trace_state;
    }
};

/// TraceState carries tracing-system-specific trace identification data
pub const TraceState = struct {
    entries: std.StringArrayHashMap([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .entries = std.StringArrayHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit();
    }

    /// Get value for a given key
    pub fn get(self: Self, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    /// Add a new key/value pair. Returns a new TraceState with the addition.
    /// Validates input according to W3C Trace Context specification.
    pub fn insert(self: Self, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !Self {
        // Validate key according to W3C spec
        if (!isValidTraceStateKey(key)) return error.InvalidTraceStateKey;
        if (!isValidTraceStateValue(value)) return error.InvalidTraceStateValue;

        var new_state = Self.init(allocator);
        try new_state.entries.ensureTotalCapacity(self.entries.count() + 1);

        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            try new_state.entries.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try new_state.entries.put(key, value);
        return new_state;
    }

    /// Update an existing value for a given key. Returns a new TraceState with the update.
    /// Validates input according to W3C Trace Context specification.
    pub fn update(self: Self, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !Self {
        if (!isValidTraceStateKey(key)) return error.InvalidTraceStateKey;
        if (!isValidTraceStateValue(value)) return error.InvalidTraceStateValue;

        var new_state = Self.init(allocator);
        try new_state.entries.ensureTotalCapacity(self.entries.count());

        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                try new_state.entries.put(key, value);
            } else {
                try new_state.entries.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        return new_state;
    }

    /// Validate TraceState key according to W3C specification
    fn isValidTraceStateKey(key: []const u8) bool {
        if (key.len == 0 or key.len > 256) return false;

        // Key format: (lcalpha | digit) 0*255(lcalpha | digit | "_" | "-"| "*" | "/")
        // Or: (lcalpha | digit) 0*240(lcalpha | digit | "_" | "-"| "*" | "/") "@" (lcalpha | digit) 0*13(lcalpha | digit | "_" | "-"| "*" | "/")
        for (key, 0..) |c, i| {
            if (i == 0) {
                if (!std.ascii.isLower(c) and !std.ascii.isDigit(c)) return false;
            } else {
                if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-' and c != '*' and c != '/' and c != '@') return false;
            }
        }
        return true;
    }

    /// Validate TraceState value according to W3C specification
    fn isValidTraceStateValue(value: []const u8) bool {
        if (value.len == 0 or value.len > 256) return false;

        // Value can contain any character except ',' and '='
        for (value) |c| {
            if (c == ',' or c == '=' or c < 0x20 or c > 0x7E) return false;
        }
        return true;
    }

    /// Delete a key/value pair. Returns a new TraceState with the deletion.
    pub fn delete(self: Self, allocator: std.mem.Allocator, key: []const u8) !Self {
        var new_state = Self.init(allocator);
        try new_state.entries.ensureTotalCapacity(self.entries.count());

        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, key)) {
                try new_state.entries.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        return new_state;
    }
};

/// Span represents a single operation within a trace.
pub const Span = struct {
    span_context: SpanContext,
    name: []const u8,
    kind: SpanKind,
    start_time_unix_nano: u64,
    end_time_unix_nano: u64,
    attributes: std.StringArrayHashMap(attribute.AttributeValue),
    events: std.ArrayList(Event),
    links: std.ArrayList(Link),
    status: ?Status,
    is_recording: bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Event represents a timestamped event in a Span
    pub const Event = struct {
        name: []const u8,
        timestamp: u64,
        attributes: std.StringArrayHashMap(attribute.AttributeValue),

        pub fn init(allocator: std.mem.Allocator, name: []const u8, timestamp: u64) Event {
            return Event{
                .name = name,
                .timestamp = timestamp,
                .attributes = std.StringArrayHashMap(attribute.AttributeValue).init(allocator),
            };
        }

        pub fn deinit(self: *Event) void {
            self.attributes.deinit();
        }
    };

    /// Link represents a link to another Span
    pub const Link = struct {
        span_context: SpanContext,
        attributes: std.StringArrayHashMap(attribute.AttributeValue),

        pub fn init(allocator: std.mem.Allocator, span_context: SpanContext) Link {
            return Link{
                .span_context = span_context,
                .attributes = std.StringArrayHashMap(attribute.AttributeValue).init(allocator),
            };
        }

        pub fn deinit(self: *Link) void {
            self.attributes.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator, span_context: SpanContext, name: []const u8, kind: SpanKind) Self {
        return Self{
            .span_context = span_context,
            .name = name,
            .kind = kind,
            .start_time_unix_nano = @as(u64, @intCast(std.time.nanoTimestamp())),
            .end_time_unix_nano = 0,
            .attributes = std.StringArrayHashMap(attribute.AttributeValue).init(allocator),
            .events = std.ArrayList(Event).init(allocator),
            .links = std.ArrayList(Link).init(allocator),
            .status = null,
            .is_recording = true,
            .allocator = allocator,
        };
    }

    /// Create a non-recording Span from a SpanContext
    /// This is used for wrapping a SpanContext to expose it as a Span interface
    pub fn fromSpanContext(span_context: SpanContext) Self {
        // Use a dummy allocator since non-recording spans don't allocate
        var dummy_allocator = std.heap.FixedBufferAllocator.init(&[_]u8{});
        return Self{
            .span_context = span_context,
            .name = "", // Non-recording spans don't have meaningful names
            .kind = .Internal,
            .start_time_unix_nano = 0,
            .end_time_unix_nano = 0,
            .attributes = std.StringArrayHashMap(attribute.AttributeValue).init(dummy_allocator.allocator()),
            .events = std.ArrayList(Event).init(dummy_allocator.allocator()),
            .links = std.ArrayList(Link).init(dummy_allocator.allocator()),
            .status = null,
            .is_recording = false, // Non-recording spans are never recording
            .allocator = dummy_allocator.allocator(),
        };
    }

    pub fn deinit(self: *Self) void {
        // Don't try to deinit if this is a non-recording span with a dummy allocator
        if (!self.is_recording and self.attributes.count() == 0 and self.events.items.len == 0 and self.links.items.len == 0) {
            return;
        }

        self.attributes.deinit();
        for (self.events.items) |*event| {
            event.deinit();
        }
        self.events.deinit();
        for (self.links.items) |*link| {
            link.deinit();
        }
        self.links.deinit();
    }

    /// Get the SpanContext for this Span
    pub fn getContext(self: Self) SpanContext {
        return self.span_context;
    }

    /// Returns true if this Span is recording data
    pub fn isRecording(self: Self) bool {
        return self.is_recording;
    }

    /// Set a single attribute on the Span
    pub fn setAttribute(self: *Self, key: []const u8, value: attribute.AttributeValue) !void {
        if (!self.is_recording) return;
        try self.attributes.put(key, value);
    }

    /// Set multiple attributes on the Span
    pub fn setAttributes(self: *Self, attributes: []const attribute.Attribute) !void {
        if (!self.is_recording) return;
        for (attributes) |attr| {
            try self.attributes.put(attr.key, attr.value);
        }
    }

    /// Add an event to the Span
    pub fn addEvent(self: *Self, name: []const u8, timestamp: ?u64, attributes: ?[]const attribute.Attribute) !void {
        if (!self.is_recording) return;

        const event_timestamp = timestamp orelse @as(u64, @intCast(std.time.nanoTimestamp()));
        var event = Event.init(self.allocator, name, event_timestamp);

        if (attributes) |attrs| {
            for (attrs) |attr| {
                try event.attributes.put(attr.key, attr.value);
            }
        }

        try self.events.append(event);
    }

    /// Add a link to another Span
    /// Records links containing SpanContext with empty TraceId or SpanId (all zeros)
    /// as long as either the attribute set or TraceState is non-empty.
    pub fn addLink(self: *Self, span_context: SpanContext, attributes: ?[]const attribute.Attribute) !void {
        if (!self.is_recording) return;

        // Check if we should record this link according to the spec
        const should_record = span_context.trace_id.isValid() or span_context.span_id.isValid() or
            (attributes != null and attributes.?.len > 0) or
            span_context.trace_state.entries.count() > 0;

        if (!should_record) return;

        var link = Link.init(self.allocator, span_context);

        if (attributes) |attrs| {
            for (attrs) |attr| {
                try link.attributes.put(attr.key, attr.value);
            }
        }

        try self.links.append(link);
    }

    /// Set the status of the Span
    pub fn setStatus(self: *Self, status: Status) void {
        if (!self.is_recording) return;

        // Status can only be set to Ok if it wasn't already set to Ok
        if (self.status) |current_status| {
            if (current_status.code == .Ok) {
                return; // Ignore attempts to change from Ok
            }
        }

        self.status = status;
    }

    /// Update the name of the Span
    pub fn updateName(self: *Self, name: []const u8) void {
        if (!self.is_recording) return;
        self.name = name;
    }

    /// Record an exception as an event
    pub fn recordException(self: *Self, exception_type: []const u8, message: []const u8, stacktrace: ?[]const u8, attributes: ?[]const attribute.Attribute) !void {
        if (!self.is_recording) return;

        const timestamp = @as(u64, @intCast(std.time.nanoTimestamp()));
        var event = Event.init(self.allocator, "exception", timestamp);

        try event.attributes.put("exception.type", .{ .string = exception_type });
        try event.attributes.put("exception.message", .{ .string = message });
        if (stacktrace) |st| {
            try event.attributes.put("exception.stacktrace", .{ .string = st });
        }

        if (attributes) |attrs| {
            for (attrs) |attr| {
                try event.attributes.put(attr.key, attr.value);
            }
        }

        try self.events.append(event);
    }

    /// End the Span
    pub fn end(self: *Self, timestamp: ?u64) void {
        if (!self.is_recording) return;

        self.end_time_unix_nano = timestamp orelse @as(u64, @intCast(std.time.nanoTimestamp()));
        self.is_recording = false;
    }
};

/// SpanKind clarifies the relationship between Spans
pub const SpanKind = enum {
    /// Default value. Indicates that the span represents an internal operation within an application
    Internal,
    /// Indicates that the span covers server-side handling of a remote request
    Server,
    /// Indicates that the span describes a request to a remote service
    Client,
    /// Indicates that the span describes the initiation or scheduling of an operation
    Producer,
    /// Indicates that the span represents the processing of an operation initiated by a producer
    Consumer,
};

/// Status represents the status of a Span
pub const Status = struct {
    code: @import("code.zig").Code,
    description: []const u8,

    pub fn unset() Status {
        return Status{ .code = .Unset, .description = "" };
    }

    pub fn ok() Status {
        return Status{ .code = .Ok, .description = "" };
    }

    pub fn error_with_description(description: []const u8) Status {
        return Status{ .code = .Error, .description = description };
    }
};

test "SpanContext creation and validation" {
    const allocator = std.testing.allocator;

    const trace_id = @import("../trace.zig").TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const span_id = @import("../trace.zig").SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    var trace_state = TraceState.init(allocator);
    defer trace_state.deinit();

    const trace_flags = @import("../trace.zig").TraceFlags.default();
    const span_context = SpanContext.init(trace_id, span_id, trace_flags, trace_state, false);

    try std.testing.expect(span_context.isValid());
    try std.testing.expect(!span_context.isRemote());
    try std.testing.expectEqual(trace_id, span_context.getTraceId());
    try std.testing.expectEqual(span_id, span_context.getSpanId());
}

test "Span operations" {
    const allocator = std.testing.allocator;

    const trace_id = @import("../trace.zig").TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const span_id = @import("../trace.zig").SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    var trace_state = TraceState.init(allocator);
    defer trace_state.deinit();

    const trace_flags = @import("../trace.zig").TraceFlags.default();
    const span_context = SpanContext.init(trace_id, span_id, trace_flags, trace_state, false);
    var span = Span.init(allocator, span_context, "test-span", .Server);
    defer span.deinit();

    try std.testing.expect(span.isRecording());
    try std.testing.expectEqualStrings("test-span", span.name);
    try std.testing.expectEqual(SpanKind.Server, span.kind);

    // Test setting attributes
    try span.setAttribute("test.key", .{ .string = "test.value" });
    const value = span.attributes.get("test.key").?;
    try std.testing.expectEqualStrings("test.value", value.string);

    // Test adding events
    try span.addEvent("test.event", null, null);
    try std.testing.expectEqual(@as(usize, 1), span.events.items.len);
    try std.testing.expectEqualStrings("test.event", span.events.items[0].name);

    // Test setting status
    span.setStatus(Status.ok());
    try std.testing.expectEqual(@import("code.zig").Code.Ok, span.status.?.code);

    // Test ending span
    span.end(null);
    try std.testing.expect(!span.isRecording());
    try std.testing.expect(span.end_time_unix_nano > 0);
}

test "TraceState operations" {
    const allocator = std.testing.allocator;

    var trace_state = TraceState.init(allocator);
    defer trace_state.entries.deinit();

    // Test valid key/value insertion
    var new_state = try trace_state.insert(allocator, "key1", "value1");
    defer new_state.entries.deinit();

    try std.testing.expectEqualStrings("value1", new_state.get("key1").?);
}

test "TraceState validation" {
    const allocator = std.testing.allocator;

    var trace_state = TraceState.init(allocator);
    defer trace_state.entries.deinit();

    // Test invalid key (empty)
    try std.testing.expectError(error.InvalidTraceStateKey, trace_state.insert(allocator, "", "value"));

    // Test invalid key (starts with uppercase)
    try std.testing.expectError(error.InvalidTraceStateKey, trace_state.insert(allocator, "Key", "value"));

    // Test invalid value (contains comma)
    try std.testing.expectError(error.InvalidTraceStateValue, trace_state.insert(allocator, "key", "val,ue"));

    // Test invalid value (contains equals)
    try std.testing.expectError(error.InvalidTraceStateValue, trace_state.insert(allocator, "key", "val=ue"));
}
