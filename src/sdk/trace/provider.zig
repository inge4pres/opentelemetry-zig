const std = @import("std");
const trace = @import("../../api/trace.zig");
const context = @import("../../api/context.zig");
const SpanProcessor = @import("span_processor.zig").SpanProcessor;
const IDGenerator = @import("id_generator.zig").IDGenerator;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

/// SDK TracerProvider that implements the same interface as API TracerProvider but with SDK functionality
pub const TracerProvider = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    processors: std.ArrayList(SpanProcessor),
    id_generator: IDGenerator,
    tracers: std.StringHashMap(*SDKTracer),
    mutex: std.Thread.Mutex,
    is_shutdown: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, id_generator: IDGenerator) !*Self {
        const self = try allocator.create(Self);

        self.* = Self{
            .allocator = allocator,
            .processors = std.ArrayList(SpanProcessor).init(allocator),
            .id_generator = id_generator,
            .tracers = std.StringHashMap(*SDKTracer).init(allocator),
            .mutex = std.Thread.Mutex{},
            .is_shutdown = std.atomic.Value(bool).init(false),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.processors.deinit();

        // Clean up tracers
        var iterator = self.tracers.valueIterator();
        while (iterator.next()) |tracer| {
            tracer.*.deinit();
            self.allocator.destroy(tracer.*);
        }
        self.tracers.deinit();
    }

    /// Add a span processor to the provider
    pub fn addSpanProcessor(self: *Self, processor: SpanProcessor) !void {
        if (self.is_shutdown.load(.acquire)) {
            return error.TracerProviderShutdown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.processors.append(processor);
    }

    /// Get a tracer with the given scope (compatible with API TracerProvider interface)
    pub fn getTracer(self: *Self, scope: InstrumentationScope) !*SDKTracer {
        if (self.is_shutdown.load(.acquire)) {
            return error.TracerProviderShutdown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Create a key for the tracer based on scope
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ scope.name, scope.version orelse "unknown" });
        defer self.allocator.free(key);

        if (self.tracers.get(key)) |existing_tracer| {
            return existing_tracer;
        }

        // Create a new tracer
        const tracer = try self.allocator.create(SDKTracer);
        tracer.* = SDKTracer.init(self, scope);

        // Store the tracer with a persistent key
        const persistent_key = try self.allocator.dupe(u8, key);
        try self.tracers.put(persistent_key, tracer);

        return tracer;
    }

    /// Shutdown the tracer provider and all associated processors
    pub fn shutdown(self: *Self) void {
        if (self.is_shutdown.swap(true, .acq_rel)) {
            return; // Already shutdown
        }

        self.mutex.lock();

        // Shutdown all processors
        for (self.processors.items) |processor| {
            processor.shutdown() catch |err| {
                std.log.err("Failed to shutdown span processor: {}", .{err});
            };
        }

        // Clean up tracers
        var iterator = self.tracers.valueIterator();
        while (iterator.next()) |tracer| {
            tracer.*.deinit();
            self.allocator.destroy(tracer.*);
        }

        // Clean up keys in the hashmap
        var key_iterator = self.tracers.keyIterator();
        while (key_iterator.next()) |key| {
            self.allocator.free(key.*);
        }

        self.tracers.deinit();
        self.processors.deinit();

        // Unlock before destroying the struct
        self.mutex.unlock();

        // Destroy self
        self.allocator.destroy(self);
    }

    /// Force flush all processors
    pub fn forceFlush(self: *Self) !void {
        if (self.is_shutdown.load(.acquire)) {
            return error.TracerProviderShutdown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.processors.items) |processor| {
            try processor.forceFlush();
        }
    }

    /// Internal method called by SDKTracer when a span starts
    pub fn onSpanStart(self: *Self, span: *trace.Span, parent_context: context.Context) void {
        if (self.is_shutdown.load(.acquire)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.processors.items) |processor| {
            processor.onStart(span, parent_context);
        }
    }

    /// Internal method called by SDKTracer when a span ends
    pub fn onSpanEnd(self: *Self, span: trace.Span) void {
        if (self.is_shutdown.load(.acquire)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.processors.items) |processor| {
            processor.onEnd(span);
        }
    }
};

/// SDKTracer implements enhanced tracing functionality
pub const SDKTracer = struct {
    provider: *TracerProvider,
    scope: InstrumentationScope,

    const Self = @This();

    pub fn init(provider: *TracerProvider, scope: InstrumentationScope) Self {
        return Self{
            .provider = provider,
            .scope = scope,
        };
    }

    pub fn deinit(self: *Self) void {
        // Nothing to clean up in the tracer itself
        _ = self;
    }

    /// Start a span with the given options (enhanced with SDK functionality)
    pub fn startSpan(
        self: Self,
        allocator: std.mem.Allocator,
        span_name: []const u8,
        options: trace.Tracer.StartOptions,
    ) !trace.Span {
        if (self.provider.is_shutdown.load(.acquire)) {
            return error.TracerProviderShutdown;
        }

        // Determine parent context and trace ID
        var parent_span_context: ?trace.SpanContext = null;
        var trace_id: trace.TraceID = undefined;

        if (options.parent_context) |parent_ctx| {
            parent_span_context = trace.extractSpanContext(parent_ctx);
        }

        // Determine trace ID based on parent
        if (parent_span_context) |parent_sc| {
            trace_id = parent_sc.trace_id;
        } else {
            // Generate new trace ID for root span using SDK ID generator
            const ids = self.provider.id_generator.newIDs();
            trace_id = ids.trace_id;
        }

        // Generate span ID using SDK ID generator
        const ids = self.provider.id_generator.newIDs();

        // Create trace state - inherit from parent if available
        var trace_state: trace.TraceState = undefined;
        if (parent_span_context) |parent_sc| {
            trace_state = parent_sc.trace_state;
        } else {
            trace_state = trace.TraceState.init(allocator);
        }

        // Create span context
        const span_context = trace.SpanContext.init(
            trace_id,
            ids.span_id,
            trace.TraceFlags.default(),
            trace_state,
            false,
        );

        // Create the span
        var span = trace.Span.init(allocator, span_context, span_name, options.kind);
        span.is_recording = true; // SDK spans are recording by default

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

        // Set start time if provided, otherwise use current time
        if (options.start_timestamp) |start_time| {
            span.start_time_unix_nano = start_time;
        } else {
            span.start_time_unix_nano = @intCast(std.time.nanoTimestamp());
        }

        // Notify processors that the span has started
        const parent_context = options.parent_context orelse context.Context.init();
        self.provider.onSpanStart(&span, parent_context);

        return span;
    }

    /// End a span - this should be called when the span is completed
    pub fn endSpan(self: Self, span: *trace.Span) void {
        if (!span.is_recording) return;

        // Set end time if not already set
        if (span.end_time_unix_nano == 0) {
            span.end_time_unix_nano = @intCast(std.time.nanoTimestamp());
        }

        // Mark span as no longer recording
        span.is_recording = false;

        // Notify processors that the span has ended
        self.provider.onSpanEnd(span.*);
    }

    /// Check if the tracer is enabled (always true for SDK tracer if not shutdown)
    pub fn isEnabled(self: Self) bool {
        return !self.provider.is_shutdown.load(.acquire);
    }
};

test "TracerProvider basic functionality" {
    const allocator = std.testing.allocator;

    // Create ID generator
    const seed = 0;
    var default_prng = std.Random.DefaultPrng.init(seed);
    var random_generator = @import("id_generator.zig").RandomIDGenerator.init(default_prng.random());
    const id_generator = random_generator.asIDGenerator();

    var provider = try TracerProvider.init(allocator, id_generator);
    defer provider.shutdown(); // shutdown handles all cleanup including self-destruction

    // Get a tracer
    const tracer = try provider.getTracer(.{ .name = "test-tracer", .version = "1.0.0" });
    try std.testing.expect(tracer.isEnabled());

    // Create a span
    var span = try tracer.startSpan(allocator, "test-span", .{});
    defer span.deinit();

    try std.testing.expectEqualStrings("test-span", span.name);
    try std.testing.expect(span.is_recording);
}

test "TracerProvider with processors" {
    const allocator = std.testing.allocator;

    // Mock processor
    const MockProcessor = struct {
        started_spans: std.ArrayList(*trace.Span),
        ended_spans: std.ArrayList(trace.Span),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return @This(){
                .started_spans = std.ArrayList(*trace.Span).init(alloc),
                .ended_spans = std.ArrayList(trace.Span).init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.started_spans.deinit();
            self.ended_spans.deinit();
        }

        pub fn onStart(ctx: *anyopaque, span: *trace.Span, _: context.Context) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.started_spans.append(span) catch {};
        }

        pub fn onEnd(ctx: *anyopaque, span: trace.Span) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ended_spans.append(span) catch {};
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}
        pub fn forceFlush(_: *anyopaque) anyerror!void {}

        pub fn asSpanProcessor(self: *@This()) SpanProcessor {
            return SpanProcessor{
                .ptr = self,
                .vtable = &.{
                    .onStartFn = onStart,
                    .onEndFn = onEnd,
                    .shutdownFn = shutdown,
                    .forceFlushFn = forceFlush,
                },
            };
        }
    };

    // Create ID generator
    const seed = 0;
    var default_prng = std.Random.DefaultPrng.init(seed);
    var random_generator = @import("id_generator.zig").RandomIDGenerator.init(default_prng.random());
    const id_generator = random_generator.asIDGenerator();

    var provider = try TracerProvider.init(allocator, id_generator);
    defer provider.shutdown(); // shutdown handles all cleanup including self-destruction

    // Add a mock processor
    var mock_processor = MockProcessor.init(allocator);
    defer mock_processor.deinit();

    try provider.addSpanProcessor(mock_processor.asSpanProcessor());

    // Get a tracer and create a span
    const tracer = try provider.getTracer(.{ .name = "test-tracer", .version = "1.0.0" });
    var span = try tracer.startSpan(allocator, "test-span", .{});
    defer span.deinit();

    // Verify the processor was called on start
    try std.testing.expectEqual(@as(usize, 1), mock_processor.started_spans.items.len);

    // End the span
    provider.onSpanEnd(span);

    // Verify the processor was called on end
    try std.testing.expectEqual(@as(usize, 1), mock_processor.ended_spans.items.len);
}
