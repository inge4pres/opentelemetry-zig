const std = @import("std");
const trace = @import("../../api/trace.zig");
const context = @import("../../api/context.zig");
const SpanExporter = @import("span_exporter.zig").SpanExporter;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

/// SpanProcessor is responsible for processing spans as they are started and ended.
pub const SpanProcessor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    pub const VTable = struct {
        onStartFn: *const fn (ctx: *anyopaque, span: *trace.Span, parent_context: context.Context) void,
        onEndFn: *const fn (ctx: *anyopaque, span: trace.Span) void,
        shutdownFn: *const fn (ctx: *anyopaque) anyerror!void,
        forceFlushFn: *const fn (ctx: *anyopaque) anyerror!void,
    };

    /// Called when a span is started
    pub fn onStart(self: Self, span: *trace.Span, parent_context: context.Context) void {
        return self.vtable.onStartFn(self.ptr, span, parent_context);
    }

    /// Called when a span is ended
    pub fn onEnd(self: Self, span: trace.Span) void {
        return self.vtable.onEndFn(self.ptr, span);
    }

    /// Shuts down the processor
    pub fn shutdown(self: Self) anyerror!void {
        return self.vtable.shutdownFn(self.ptr);
    }

    /// Forces a flush of any buffered spans
    pub fn forceFlush(self: Self) anyerror!void {
        return self.vtable.forceFlushFn(self.ptr);
    }
};

/// SimpleProcessor passes finished spans to the configured SpanExporter immediately
pub const SimpleProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, exporter: SpanExporter) Self {
        return Self{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn asSpanProcessor(self: *Self) SpanProcessor {
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

    fn onStart(_: *anyopaque, _: *trace.Span, _: context.Context) void {
        // SimpleProcessor doesn't need to do anything on start
    }

    fn onEnd(ctx: *anyopaque, span: trace.Span) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Only process recording spans
        if (!span.is_recording) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Export the single span
        var spans = [_]trace.Span{span};
        self.exporter.exportSpans(spans[0..]) catch |err| {
            std.log.err("SimpleProcessor failed to export span: {}", .{err});
        };
    }

    fn shutdown(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        // Shutdown is handled by the exporter
        return;
    }

    fn forceFlush(_: *anyopaque) anyerror!void {
        // SimpleProcessor exports immediately, so nothing to flush
        return;
    }
};

/// BatchingProcessor batches finished spans and passes them to the configured SpanExporter
pub const BatchingProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: SpanExporter,

    // Configuration
    max_queue_size: usize,
    scheduled_delay_millis: u64,
    export_timeout_millis: u64,
    max_export_batch_size: usize,

    // State
    queue: std.ArrayList(trace.Span),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    export_thread: ?std.Thread,
    should_shutdown: std.atomic.Value(bool),

    const Self = @This();

    pub const Config = struct {
        max_queue_size: usize = 2048,
        scheduled_delay_millis: u64 = 5000,
        export_timeout_millis: u64 = 30000,
        max_export_batch_size: usize = 512,
    };

    pub fn init(allocator: std.mem.Allocator, exporter: SpanExporter, config: Config) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .exporter = exporter,
            .max_queue_size = config.max_queue_size,
            .scheduled_delay_millis = config.scheduled_delay_millis,
            .export_timeout_millis = config.export_timeout_millis,
            .max_export_batch_size = config.max_export_batch_size,
            .queue = std.ArrayList(trace.Span).init(allocator),
            .mutex = std.Thread.Mutex{},
            .condition = std.Thread.Condition{},
            .export_thread = null,
            .should_shutdown = std.atomic.Value(bool).init(false),
        };

        // Start the export thread
        self.export_thread = try std.Thread.spawn(.{}, exportLoop, .{self});

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Shutdown should have been called before deinit
        std.debug.assert(self.export_thread == null);
        self.queue.deinit();
        self.allocator.destroy(self);
    }

    pub fn asSpanProcessor(self: *Self) SpanProcessor {
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

    fn onStart(_: *anyopaque, _: *trace.Span, _: context.Context) void {
        // BatchingProcessor doesn't need to do anything on start
    }

    fn onEnd(ctx: *anyopaque, span: trace.Span) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Only process recording spans
        if (!span.is_recording) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        // If queue is full, drop the span
        if (self.queue.items.len >= self.max_queue_size) {
            std.log.warn("BatchingProcessor queue full, dropping span", .{});
            return;
        }

        // Add span to queue
        self.queue.append(span) catch {
            std.log.err("BatchingProcessor failed to add span to queue", .{});
            return;
        };

        // Check if we should trigger an export
        if (self.queue.items.len >= self.max_export_batch_size) {
            self.condition.signal();
        }
    }

    fn shutdown(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Signal shutdown
        self.should_shutdown.store(true, .release);

        // Wake up the export thread
        self.mutex.lock();
        self.condition.signal();
        self.mutex.unlock();

        // Wait for the export thread to finish
        if (self.export_thread) |thread| {
            thread.join();
            self.export_thread = null;
        }
    }

    fn forceFlush(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        // Export all pending spans
        if (self.queue.items.len > 0) {
            self.exportBatch();
        }
    }

    fn exportLoop(self: *Self) void {
        while (!self.should_shutdown.load(.acquire)) {
            self.mutex.lock();

            // Wait for either shutdown signal, timeout, or queue to reach batch size
            if (self.queue.items.len < self.max_export_batch_size) {
                self.condition.timedWait(&self.mutex, self.scheduled_delay_millis * std.time.ns_per_ms) catch {};
            }

            // Export if we have spans or if shutting down
            if (self.queue.items.len > 0) {
                self.exportBatch();
            }

            self.mutex.unlock();
        }

        // Final export on shutdown
        self.mutex.lock();
        if (self.queue.items.len > 0) {
            self.exportBatch();
        }
        self.mutex.unlock();
    }

    /// Must be called while holding the mutex
    fn exportBatch(self: *Self) void {
        if (self.queue.items.len == 0) return;

        const batch_size = @min(self.queue.items.len, self.max_export_batch_size);
        const spans_to_export = self.queue.items[0..batch_size];

        // Make a copy of the spans to export (since the exporter might take ownership)
        const export_spans = self.allocator.alloc(trace.Span, batch_size) catch {
            std.log.err("BatchingProcessor failed to allocate memory for export batch", .{});
            return;
        };
        defer self.allocator.free(export_spans);

        @memcpy(export_spans, spans_to_export);

        // Remove exported spans from queue
        std.mem.copyForwards(trace.Span, self.queue.items, self.queue.items[batch_size..]);
        self.queue.shrinkRetainingCapacity(self.queue.items.len - batch_size);

        // Export the batch (unlock mutex during export)
        self.mutex.unlock();
        defer self.mutex.lock();

        self.exporter.exportSpans(export_spans) catch |err| {
            std.log.err("BatchingProcessor failed to export span batch: {}", .{err});
        };
    }
};

test "SimpleProcessor basic functionality" {
    const allocator = std.testing.allocator;

    // Mock exporter
    const MockExporter = struct {
        exported_spans: std.ArrayList(trace.Span),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return @This(){
                .exported_spans = std.ArrayList(trace.Span).init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.exported_spans.deinit();
        }

        pub fn exportSpans(ctx: *anyopaque, spans: []trace.Span) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.exported_spans.appendSlice(spans);
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}

        pub fn asSpanExporter(self: *@This()) SpanExporter {
            return SpanExporter{
                .ptr = self,
                .vtable = &.{
                    .exportSpansFn = exportSpans,
                    .shutdownFn = shutdown,
                },
            };
        }
    };

    var mock_exporter = MockExporter.init(allocator);
    defer mock_exporter.deinit();

    const exporter = mock_exporter.asSpanExporter();
    var processor = SimpleProcessor.init(allocator, exporter);
    const span_processor = processor.asSpanProcessor();

    // Create a test span
    const trace_id = trace.TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const span_id = trace.SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    var trace_state = trace.TraceState.init(allocator);
    defer trace_state.deinit();

    const span_context = trace.SpanContext.init(trace_id, span_id, trace.TraceFlags.default(), trace_state, false);
    const scope = InstrumentationScope{ .name = "test-lib", .version = "1.0.0" };
    var test_span = trace.Span.init(allocator, span_context, "test-span", .Internal, scope);
    defer test_span.deinit();

    // Make the span recording
    test_span.is_recording = true;

    // Test onEnd
    span_processor.onEnd(test_span);

    // Verify the span was exported
    try std.testing.expectEqual(@as(usize, 1), mock_exporter.exported_spans.items.len);
    try std.testing.expectEqualStrings("test-span", mock_exporter.exported_spans.items[0].name);
}

test "BatchingProcessor basic functionality" {
    const allocator = std.testing.allocator;

    // Mock exporter (same as above)
    const MockExporter = struct {
        exported_spans: std.ArrayList(trace.Span),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return @This(){
                .exported_spans = std.ArrayList(trace.Span).init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.exported_spans.deinit();
        }

        pub fn exportSpans(ctx: *anyopaque, spans: []trace.Span) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.exported_spans.appendSlice(spans);
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}

        pub fn asSpanExporter(self: *@This()) SpanExporter {
            return SpanExporter{
                .ptr = self,
                .vtable = &.{
                    .exportSpansFn = exportSpans,
                    .shutdownFn = shutdown,
                },
            };
        }
    };

    var mock_exporter = MockExporter.init(allocator);
    defer mock_exporter.deinit();

    const exporter = mock_exporter.asSpanExporter();
    var processor = try BatchingProcessor.init(allocator, exporter, .{
        .max_export_batch_size = 2, // Small batch size for testing
        .scheduled_delay_millis = 100, // Short delay for testing
    });
    defer {
        const span_processor = processor.asSpanProcessor();
        span_processor.shutdown() catch {};
        processor.deinit();
    }

    const span_processor = processor.asSpanProcessor();

    // Create test spans
    var spans: [3]trace.Span = undefined;
    var trace_states: [3]trace.TraceState = undefined;

    for (&spans, &trace_states, 0..) |*span, *ts, i| {
        const trace_id = trace.TraceID.init([16]u8{ @intCast(i), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
        const span_id = trace.SpanID.init([8]u8{ @intCast(i), 2, 3, 4, 5, 6, 7, 8 });
        ts.* = trace.TraceState.init(allocator);

        const span_context = trace.SpanContext.init(trace_id, span_id, trace.TraceFlags.default(), ts.*, false);
        const scope = InstrumentationScope{ .name = "test-lib", .version = "1.0.0" };
        span.* = trace.Span.init(allocator, span_context, "test-span", .Internal, scope);
        span.is_recording = true;
    }
    defer {
        for (&spans, &trace_states) |*span, *ts| {
            span.deinit();
            ts.deinit();
        }
    }

    // Add spans - this should trigger an export when batch size is reached
    for (spans) |span| {
        span_processor.onEnd(span);
    }

    // Wait a bit for the background thread to process
    std.time.sleep(200 * std.time.ns_per_ms);

    // Force flush to export remaining spans
    try span_processor.forceFlush();

    // Verify spans were exported
    try std.testing.expectEqual(@as(usize, 3), mock_exporter.exported_spans.items.len);
}
