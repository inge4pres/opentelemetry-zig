const std = @import("std");
const context = @import("../../api/context.zig");
const SpanProcessor = @import("span_processor.zig").SpanProcessor;
const IDGenerator = @import("id_generator.zig").IDGenerator;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

const trace_api = @import("../../api/trace.zig");
const TracerProviderAPI = trace_api.TracerProvider;
const TracerAPI = trace_api.Tracer;

const RandomIDGenerator = @import("id_generator.zig").RandomIDGenerator;

/// SDK TracerProvider implementation
pub const TracerProvider = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    tracers: std.HashMapUnmanaged(
        InstrumentationScope,
        *TracerAPI,
        InstrumentationScope.HashContext,
        std.hash_map.default_max_load_percentage,
    ),
    processors: std.ArrayList(SpanProcessor),
    id_generator: IDGenerator,
    mutex: std.Thread.Mutex,
    is_shutdown: std.atomic.Value(bool),
    // Interface implementation
    tracer_provider: TracerProviderAPI,

    pub fn init(allocator: std.mem.Allocator, id_generator: IDGenerator) !*Self {
        const self = try allocator.create(Self);

        self.* = Self{
            .allocator = allocator,
            .tracers = .empty,
            .processors = std.ArrayList(SpanProcessor).init(allocator),
            .id_generator = id_generator,
            .mutex = std.Thread.Mutex{},
            .is_shutdown = std.atomic.Value(bool).init(false),
            .tracer_provider = TracerProviderAPI{
                .ptr = undefined, // Will be set after creation
                .vtable = &.{
                    .getTracerFn = getTracerImpl,
                    .shutdownFn = shutdownImpl,
                },
            },
        };

        // Set the ptr to point to self
        self.tracer_provider.ptr = self;

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.processors.deinit();
    }

    /// Get the TracerProvider interface for this implementation
    pub fn asTracerProvider(self: *Self) *TracerProviderAPI {
        return &self.tracer_provider;
    }

    /// Implementation of TracerProvider.getTracer
    fn getTracerImpl(ptr: *anyopaque, scope: InstrumentationScope) anyerror!*TracerAPI {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.getTracer(scope);
    }

    /// Implementation of TracerProvider.shutdown
    fn shutdownImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.shutdown();
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

    /// Get a tracer with the given scope (returns interface)
    pub fn getTracer(self: *Self, scope: InstrumentationScope) !*TracerAPI {
        if (self.is_shutdown.load(.acquire)) {
            return error.TracerProviderShutdown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we already have an SDKTracer for this scope
        if (self.tracers.get(scope)) |existing_tracer| {
            return &existing_tracer.tracer;
        }

        // Create a new SDKTracer
        const tracer = try self.allocator.create(TracerAPI);
        tracer.* = TracerAPI.init(self, scope);
        // Set the tracer interface ptr to point to the interface itself
        tracer.tracer.ptr = &tracer.tracer;

        // Cache the tracer
        try self.tracers.put(self.allocator, scope, tracer);

        return &tracer.tracer;
    }

    /// Get the SDK tracer directly (for internal use)
    pub fn getSDKTracer(self: *Self, scope: InstrumentationScope) !*TracerAPI {
        if (self.is_shutdown.load(.acquire)) {
            return error.TracerProviderShutdown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we already have an SDKTracer for this scope
        if (self.tracers.get(scope)) |existing_tracer| {
            return existing_tracer;
        }

        // Create a new SDKTracer
        const tracer = try self.allocator.create(TracerAPI);
        tracer.* = TracerAPI.init(self, scope);
        // Set the tracer interface ptr to point to the interface itself
        tracer.tracer.ptr = &tracer.tracer;

        // Cache the tracer
        try self.tracers.put(self.allocator, scope, tracer);

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

        // Clean up SDKTracers
        var sdk_tracers_iter = self.tracers.valueIterator();
        while (sdk_tracers_iter.next()) |sdk_tracer| {
            sdk_tracer.*.deinit();
            self.allocator.destroy(sdk_tracer.*);
        }
        self.tracers.deinit(self.allocator);

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
    pub fn onSpanStart(self: *Self, span: *trace_api.Span, parent_context: context.Context) void {
        if (self.is_shutdown.load(.acquire)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.processors.items) |processor| {
            processor.onStart(span, parent_context);
        }
    }

    /// Internal method called by SDKTracer when a span ends
    pub fn onSpanEnd(self: *Self, span: trace_api.Span) void {
        if (self.is_shutdown.load(.acquire)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.processors.items) |processor| {
            processor.onEnd(span);
        }
    }
};

/// SDKTracer implements enhanced tracing functionality
pub const Tracer = struct {
    provider: *TracerProviderAPI,
    scope: InstrumentationScope,
    // Interface implementation
    tracer: TracerAPI,

    const Self = @This();

    pub fn init(provider: *TracerProviderAPI, scope: InstrumentationScope) Self {
        return Self{
            .provider = provider,
            .scope = scope,
            .tracer = TracerAPI{
                .ptr = undefined, // Will be set after creation
                .vtable = &.{
                    .startSpanFn = startSpanImpl,
                    .isEnabledFn = isEnabledImpl,
                },
            },
        };
    }

    pub fn deinit(self: *Self) void {
        // Nothing to clean up in the tracer itself
        _ = self;
    }

    /// Implementation of Tracer.startSpan
    fn startSpanImpl(ptr: *anyopaque, allocator: std.mem.Allocator, span_name: []const u8, options: TracerAPI.StartOptions) anyerror!trace_api.Span {
        const tracer_iface: *TracerAPI = @ptrCast(@alignCast(ptr));
        const self: *Self = @fieldParentPtr("tracer", tracer_iface);
        return self.startSpan(allocator, span_name, options);
    }

    /// Implementation of Tracer.isEnabled
    fn isEnabledImpl(ptr: *anyopaque) bool {
        const tracer_iface: *TracerAPI = @ptrCast(@alignCast(ptr));
        const self: *Self = @fieldParentPtr("tracer", tracer_iface);
        return self.isEnabled();
    }

    /// Start a span with the given options (enhanced with SDK functionality)
    pub fn startSpan(
        self: Self,
        allocator: std.mem.Allocator,
        span_name: []const u8,
        options: TracerAPI.StartOptions,
    ) !trace_api.Span {
        if (self.provider.is_shutdown.load(.acquire)) {
            return error.TracerProviderShutdown;
        }

        // Determine parent context and trace ID
        var parent_span_context: ?trace_api.SpanContext = null;
        var trace_id: trace_api.TraceID = undefined;

        if (options.parent_context) |parent_ctx| {
            parent_span_context = trace_api.extractSpanContext(parent_ctx);
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
        var trace_state: trace_api.TraceState = undefined;
        if (parent_span_context) |parent_sc| {
            trace_state = parent_sc.trace_state;
        } else {
            trace_state = trace_api.TraceState.init(allocator);
        }

        // Create span context
        const span_context = trace_api.SpanContext.init(
            trace_id,
            ids.span_id,
            trace_api.TraceFlags.default(),
            trace_state,
            false,
        );

        // Create the span with instrumentation scope
        var span = trace_api.Span.init(allocator, span_context, span_name, options.kind, self.scope);
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
    pub fn endSpan(self: Self, span: *trace_api.Span) void {
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
    const random_generator = RandomIDGenerator.init(default_prng.random());

    var provider = try TracerProviderAPI.init(allocator, IDGenerator{ .Random = random_generator });
    defer provider.shutdown(); // Use shutdown to properly destroy the provider

    // Get a tracer via the interface
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
        started_spans: std.ArrayList(*trace_api.Span),
        ended_spans: std.ArrayList(trace_api.Span),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return @This(){
                .started_spans = std.ArrayList(*trace_api.Span).init(alloc),
                .ended_spans = std.ArrayList(trace_api.Span).init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.started_spans.deinit();
            self.ended_spans.deinit();
        }

        pub fn onStart(ctx: *anyopaque, span: *trace_api.Span, _: context.Context) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.started_spans.append(span) catch {};
        }

        pub fn onEnd(ctx: *anyopaque, span: trace_api.Span) void {
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
    const random_generator = RandomIDGenerator.init(default_prng.random());

    var provider = try TracerProviderAPI.init(allocator, IDGenerator{ .Random = random_generator });
    defer provider.shutdown(); // Use shutdown to properly destroy the provider

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

    // End the span using the SDK method
    const sdk_tracer = try provider.getSDKTracer(.{ .name = "test-tracer", .version = "1.0.0" });
    sdk_tracer.endSpan(&span);

    // Verify the processor was called on end
    try std.testing.expectEqual(@as(usize, 1), mock_processor.ended_spans.items.len);
}
