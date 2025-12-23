const std = @import("std");
const context = @import("../../api/context.zig");
const SpanProcessor = @import("span_processor.zig").SpanProcessor;
const BatchingProcessor = @import("span_processor.zig").BatchingProcessor;
const SimpleProcessor = @import("span_processor.zig").SimpleProcessor;
const IDGenerator = @import("id_generator.zig").IDGenerator;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

const trace_api = @import("../../api/trace.zig");
const TracerProviderAPI = trace_api.TracerProviderImpl;
const TracerAPI = trace_api.TracerImpl;

const RandomIDGenerator = @import("id_generator.zig").RandomIDGenerator;

const Attributes = @import("../../attributes.zig").Attributes;
const Attribute = @import("../../attributes.zig").Attribute;

const SpanExporter = @import("span_exporter.zig").SpanExporter;

// Import configuration module
const Configuration = @import("../config.zig").Configuration;
const TraceConfig = @import("../config.zig").TraceConfig;
const resource_attributes = @import("../resource.zig");

/// SDK TracerProvider implementation
pub const TracerProvider = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    tracers: std.HashMapUnmanaged(
        InstrumentationScope,
        *Tracer,
        InstrumentationScope.HashContext,
        std.hash_map.default_max_load_percentage,
    ),
    processors: std.ArrayList(SpanProcessor),
    id_generator: IDGenerator,
    mutex: std.Thread.Mutex,
    is_shutdown: std.atomic.Value(bool),
    // Interface implementation
    tracer_provider: TracerProviderAPI,
    // Configuration (accessed internally from global singleton)
    config: ?*const Configuration,
    sdk_disabled: bool,
    // Resource attributes for this provider
    resource: ?[]const Attribute,

    pub fn init(allocator: std.mem.Allocator, id_generator: IDGenerator) !*Self {
        // Access global configuration (transparent to user)
        const cfg = Configuration.get();
        const sdk_disabled = if (cfg) |c| c.sdk_disabled else false;

        const self = try allocator.create(Self);

        self.* = Self{
            .allocator = allocator,
            .tracers = .empty,
            .processors = std.ArrayList(SpanProcessor){},
            .id_generator = id_generator,
            .mutex = std.Thread.Mutex{},
            .is_shutdown = std.atomic.Value(bool).init(false),
            .tracer_provider = TracerProviderAPI{
                .getTracerFn = getTracerImpl,
                .shutdownFn = shutdownImpl,
            },
            .sdk_disabled = sdk_disabled,
            .config = cfg,
            .resource = if (sdk_disabled) null else if (cfg) |c| try resource_attributes.buildFromConfig(allocator, c) else null,
        };

        if (sdk_disabled) {
            std.log.info("TracerProvider: SDK disabled via OTEL_SDK_DISABLED", .{});
        }

        return self;
    }

    /// Helper: Create a BatchingProcessor configured from environment variables
    /// This is a convenience method that uses OTEL_BSP_* environment variables
    pub fn createBatchProcessorFromConfig(
        self: *Self,
        exporter: SpanExporter,
    ) !*BatchingProcessor {
        const tc = self.config.?.trace_config;
        return try BatchingProcessor.init(self.allocator, exporter, .{
            .max_queue_size = @intCast(tc.bsp_max_queue_size),
            .scheduled_delay_millis = tc.bsp_schedule_delay_ms,
            .export_timeout_millis = tc.bsp_export_timeout_ms,
            .max_export_batch_size = @intCast(tc.bsp_max_export_batch_size),
        });
    }

    pub fn deinit(self: *Self) void {
        // Clean up all tracers
        var it = self.tracers.valueIterator();
        while (it.next()) |tracer| {
            self.allocator.destroy(tracer.*);
        }
        self.tracers.deinit(self.allocator);

        self.processors.deinit(self.allocator);
        if (self.resource) |res| {
            resource_attributes.freeResource(self.allocator, res);
        }
    }

    /// Get the TracerProvider interface for this implementation
    pub fn asTracerProvider(self: *Self) *TracerProviderAPI {
        return &self.tracer_provider;
    }

    /// Implementation of TracerProvider.getTracer
    fn getTracerImpl(tracer_provider: *TracerProviderAPI, scope: InstrumentationScope) anyerror!*TracerAPI {
        const self: *Self = @fieldParentPtr("tracer_provider", tracer_provider);
        return self.getTracer(scope);
    }

    /// Implementation of TracerProvider.shutdown
    fn shutdownImpl(tracer_provider: *TracerProviderAPI) void {
        const self: *Self = @fieldParentPtr("tracer_provider", tracer_provider);
        self.shutdown();
    }

    /// Add a span processor to the provider
    pub fn addSpanProcessor(self: *Self, processor: SpanProcessor) !void {
        if (self.is_shutdown.load(.acquire)) {
            return error.TracerProviderShutdown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.processors.append(self.allocator, processor);
    }

    /// Get a tracer with the given scope (returns interface)
    pub fn getTracer(self: *Self, scope: InstrumentationScope) !*TracerAPI {
        if (self.is_shutdown.load(.acquire)) {
            return error.TracerProviderShutdown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we already have a Tracer for this scope
        if (self.tracers.get(scope)) |existing_tracer| {
            return &existing_tracer.tracer;
        }

        // Create a new SDKTracer
        const tracer = try self.allocator.create(Tracer);
        tracer.* = Tracer.init(self, scope);

        // Cache the tracer
        try self.tracers.put(self.allocator, scope, tracer);

        return &tracer.tracer;
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

        self.processors.deinit(self.allocator);

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
        if (self.sdk_disabled or self.is_shutdown.load(.acquire)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.processors.items) |processor| {
            processor.onStart(span, parent_context);
        }
    }

    /// Internal method called by SDKTracer when a span ends
    pub fn onSpanEnd(self: *Self, span: trace_api.Span) void {
        if (self.sdk_disabled or self.is_shutdown.load(.acquire)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.processors.items) |processor| {
            processor.onEnd(span);
        }
    }
};

/// SDKTracer implements enhanced tracing functionality
pub const Tracer = struct {
    provider: *TracerProvider,
    scope: InstrumentationScope,
    // Interface implementation
    tracer: TracerAPI,

    const Self = @This();

    pub fn init(provider: *TracerProvider, scope: InstrumentationScope) Self {
        return Self{
            .provider = provider,
            .scope = scope,
            .tracer = TracerAPI{
                .startSpanFn = startSpan,
                .isEnabledFn = isEnabled,
                .endSpanFn = endSpanImpl,
            },
        };
    }

    pub fn deinit(self: *Self) void {
        // Nothing to clean up in the tracer itself
        _ = self;
    }

    /// Implementation of Tracer.startSpan
    fn startSpan(
        tracer: *TracerAPI,
        allocator: std.mem.Allocator,
        span_name: []const u8,
        options: TracerAPI.StartOptions,
    ) !trace_api.Span {
        const self: *Self = @fieldParentPtr("tracer", tracer);
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
        span.start_time_unix_nano = options.start_timestamp orelse @intCast(std.time.nanoTimestamp());

        // Notify processors that the span has started
        const parent_context = options.parent_context orelse context.Context.init();
        self.provider.onSpanStart(&span, parent_context);

        return span;
    }

    /// Implementation of Tracer.isEnabled
    /// Checks if the tracer is enabled (always true for SDK tracer if not shutdown)
    fn isEnabled(tracer: *TracerAPI) bool {
        const self: *Self = @fieldParentPtr("tracer", tracer);
        return !self.provider.is_shutdown.load(.acquire);
    }

    /// Implementation of Tracer.endSpan
    /// End a span - this should be called when the span is completed
    fn endSpanImpl(tracer: *TracerAPI, span: *trace_api.Span) void {
        const self: *Self = @fieldParentPtr("tracer", tracer);
        self.endSpan(span);
    }

    /// End a span - this should be called when the span is completed
    pub fn endSpan(self: Self, span: *trace_api.Span) void {
        defer span.end(null);
        if (!span.is_recording) return;

        // Notify processors that the span has ended
        self.provider.onSpanEnd(span.*);
    }
};

test "TracerProvider basic functionality" {
    const allocator = std.testing.allocator;

    // Create ID generator
    const seed = 0;
    var default_prng = std.Random.DefaultPrng.init(seed);
    const random_generator = RandomIDGenerator.init(default_prng.random());

    var provider = try TracerProvider.init(allocator, IDGenerator{ .Random = random_generator });
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

// Mock processor
const MockProcessor = struct {
    allocator: std.mem.Allocator,
    started_spans: std.ArrayList(*trace_api.Span),
    ended_spans: std.ArrayList(trace_api.Span),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return @This(){
            .allocator = allocator,
            .started_spans = std.ArrayList(*trace_api.Span){},
            .ended_spans = std.ArrayList(trace_api.Span){},
        };
    }

    pub fn deinit(self: *@This()) void {
        self.started_spans.deinit(self.allocator);
        self.ended_spans.deinit(self.allocator);
    }

    pub fn onStart(ctx: *anyopaque, span: *trace_api.Span, _: context.Context) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.started_spans.append(self.allocator, span) catch {};
    }

    pub fn onEnd(ctx: *anyopaque, span: trace_api.Span) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.ended_spans.append(self.allocator, span) catch {};
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
test "TracerProvider with processors" {
    const allocator = std.testing.allocator;

    // Create ID generator
    const seed = 0;
    var default_prng = std.Random.DefaultPrng.init(seed);
    const random_generator = RandomIDGenerator.init(default_prng.random());

    var provider = try TracerProvider.init(allocator, IDGenerator{ .Random = random_generator });
    defer provider.shutdown(); // Use shutdown to properly destroy the provider

    // Add a mock processor
    var mock_processor = MockProcessor.init(allocator);
    defer mock_processor.deinit();

    try provider.addSpanProcessor(mock_processor.asSpanProcessor());

    // Get a tracer and create a span
    const tracer = try provider.getTracer(.{ .name = "test-tracer", .version = "1.0.0" });
    var span = try tracer.startSpan(allocator, "test-span", .{});
    defer span.deinit();
    defer tracer.endSpan(&span);

    // Verify the processor was called on start
    try std.testing.expectEqual(@as(usize, 1), mock_processor.started_spans.items.len);
}

test "TracerProvider with config from environment" {
    const allocator = std.testing.allocator;

    const cfg = try Configuration.initFromEnv(allocator);
    defer cfg.deinit();
    Configuration.set(cfg);

    // Create provider (it will read default config from env)
    const seed = 0;
    var default_prng = std.Random.DefaultPrng.init(seed);
    const random_generator = RandomIDGenerator.init(default_prng.random());

    var provider = try TracerProvider.init(allocator, IDGenerator{ .Random = random_generator });
    defer provider.shutdown();

    // Verify config was loaded with defaults
    try std.testing.expectEqual(@as(u32, 2048), provider.config.?.trace_config.bsp_max_queue_size);
    try std.testing.expectEqual(@as(u64, 5000), provider.config.?.trace_config.bsp_schedule_delay_ms);
    try std.testing.expectEqual(@as(u32, 512), provider.config.?.trace_config.bsp_max_export_batch_size);
    try std.testing.expectEqual(TraceConfig.Sampler.parentbased_always_on, provider.config.?.trace_config.sampler);
}

test "TracerProvider end span with links and events" {
    const allocator = std.testing.allocator;

    const seed = 0;
    var default_prng = std.Random.DefaultPrng.init(seed);
    const random_generator = RandomIDGenerator.init(default_prng.random());

    var provider = try TracerProvider.init(allocator, IDGenerator{ .Random = random_generator });
    defer provider.shutdown(); // Use shutdown to properly destroy the provider

    // Get a tracer via the interface
    const tracer = try provider.getTracer(.{ .name = "test-tracer", .version = "1.0.0" });

    // Create a span with links and attributes
    var link_span_context = trace_api.SpanContext.init(
        trace_api.TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        trace_api.SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        trace_api.TraceFlags.default(),
        trace_api.TraceState.init(allocator),
        false,
    );
    defer link_span_context.trace_state.deinit();

    const link = trace_api.Link.init(allocator, link_span_context);

    const attributes = try Attributes.from(allocator, .{
        "key1", @as([]const u8, "value1"),
        "key2", @as(i64, 42),
    });
    defer allocator.free(attributes.?);

    var span = try tracer.startSpan(allocator, "test-span-with-link", .{
        .links = &[_]trace_api.Link{link},
        .attributes = attributes,
    });
    defer span.deinit();
    defer tracer.endSpan(&span);

    try std.testing.expectEqualStrings("test-span-with-link", span.name);
    try std.testing.expect(span.is_recording);
    try std.testing.expectEqual(@as(usize, 1), span.links.items.len);
    try std.testing.expectEqual(@as(usize, 2), span.attributes.count());
}
