const std = @import("std");
const clock = @import("clock");
const trace = @import("../../api/trace.zig");
const context = @import("../../api/context.zig");
const SpanExporter = @import("span_exporter.zig").SpanExporter;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const attribute = @import("../../attributes.zig");
const SpanAttributes = std.StringArrayHashMapUnmanaged(attribute.AttributeValue);

const SpanQueue = struct {
    buffer: []trace.Span = &.{},
    head: usize = 0,
    len: usize = 0,

    fn init(allocator: std.mem.Allocator, capacity: usize) !SpanQueue {
        return .{ .buffer = try allocator.alloc(trace.Span, capacity) };
    }

    fn deinit(self: *SpanQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.* = .{};
    }

    fn deinitItems(self: *SpanQueue) void {
        for (0..self.len) |i| {
            const index = (self.head + i) % self.buffer.len;
            self.buffer[index].deinit();
        }
    }

    fn push(self: *SpanQueue, span: trace.Span) bool {
        if (self.len >= self.buffer.len) return false;
        const index = (self.head + self.len) % self.buffer.len;
        self.buffer[index] = span;
        self.len += 1;
        return true;
    }

    fn popBatch(self: *SpanQueue, dest: []trace.Span) []trace.Span {
        const count = @min(dest.len, self.len);
        for (0..count) |i| {
            const index = (self.head + i) % self.buffer.len;
            dest[i] = self.buffer[index];
        }
        self.len -= count;
        if (self.len == 0) {
            self.head = 0;
        } else {
            self.head = (self.head + count) % self.buffer.len;
        }
        return dest[0..count];
    }
};

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
    mutex: std.Io.Mutex,
    io: std.Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, exporter: SpanExporter) Self {
        return Self{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = std.Io.Mutex.init,
            .io = io,
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
        // `span.end()` has already flipped `is_recording` to false before
        // the tracer calls onEnd, so we do not gate on it here — every
        // ended SDK span is eligible for export.
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Export the single span
        var spans = [_]trace.Span{span};
        self.exporter.exportSpans(spans[0..]) catch |err| {
            std.log.err("SimpleProcessor failed to export span: {}", .{err});
        };
    }

    fn shutdown(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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
    queue: SpanQueue,
    mutex: std.Io.Mutex,
    wake: std.Io.Event,
    io: std.Io,
    export_task: ?std.Io.Future(void),
    should_shutdown: std.atomic.Value(bool),

    const Self = @This();

    pub const Config = struct {
        max_queue_size: usize = 2048,
        scheduled_delay_millis: u64 = 5000,
        export_timeout_millis: u64 = 30000,
        max_export_batch_size: usize = 512,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, exporter: SpanExporter, config: Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const max_export_batch_size = if (config.max_queue_size == 0)
            0
        else
            @max(@as(usize, 1), @min(config.max_export_batch_size, config.max_queue_size));
        var queue = try SpanQueue.init(allocator, config.max_queue_size);
        errdefer queue.deinit(allocator);

        self.* = Self{
            .allocator = allocator,
            .exporter = exporter,
            .max_queue_size = config.max_queue_size,
            .scheduled_delay_millis = config.scheduled_delay_millis,
            .export_timeout_millis = config.export_timeout_millis,
            .max_export_batch_size = max_export_batch_size,
            .queue = queue,
            .mutex = std.Io.Mutex.init,
            .wake = .unset,
            .io = io,
            .export_task = null,
            .should_shutdown = std.atomic.Value(bool).init(false),
        };

        // Start the background export task using io.concurrent
        self.export_task = try io.concurrent(exportLoop, .{self});

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Shutdown should have been called before deinit
        std.debug.assert(self.export_task == null);
        self.queue.deinitItems();
        self.queue.deinit(self.allocator);
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
        // `span.end()` has already flipped `is_recording` to false before
        // the tracer calls onEnd, so we do not gate on it here — every
        // ended SDK span is eligible for batching.
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // If queue is full, drop the span
        if (self.queue.len >= self.max_queue_size) {
            std.log.warn("BatchingProcessor queue full, dropping span", .{});
            return;
        }

        const queued_span = cloneSpan(self.allocator, span) catch {
            std.log.err("BatchingProcessor failed to copy span for queue", .{});
            return;
        };

        if (!self.queue.push(queued_span)) {
            std.log.err("BatchingProcessor failed to add span to queue", .{});
            var owned_span = queued_span;
            owned_span.deinit();
            return;
        }

        // Check if we should trigger an export
        if (self.queue.len >= self.max_export_batch_size) {
            self.wake.set(self.io);
        }
    }

    fn shutdown(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Signal shutdown
        self.should_shutdown.store(true, .release);

        // Cancel the background task (unblocks its wait and waits for it to finish)
        if (self.export_task) |*task| {
            task.cancel(self.io);
            self.export_task = null;
        }
    }

    fn forceFlush(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Export all pending spans
        while (self.queue.len > 0) {
            if (!self.exportBatch()) break;
        }
    }

    fn exportLoop(self: *Self) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.should_shutdown.load(.acquire)) {
                while (self.queue.len > 0) {
                    if (!self.exportBatch()) break;
                }
                self.mutex.unlock(self.io);
                break;
            }
            // Only arm the wait if we don't already have a full batch ready.
            // Resetting unconditionally races with onEnd: if onEnd fires
            // wake.set() between the previous iteration's unlock and the
            // reset below, the signal is lost and we block for the full
            // scheduled_delay_millis even though a batch is queued.
            // When max_export_batch_size == 0 (e.g. max_queue_size == 0 via
            // OTEL_BSP_MAX_QUEUE_SIZE=0) the naive `len < batch` comparison
            // is false for an empty queue and would spin; always wait in
            // that degenerate case.
            const should_wait = self.max_export_batch_size == 0 or
                self.queue.len < self.max_export_batch_size;
            if (should_wait) self.wake.reset();
            self.mutex.unlock(self.io);

            if (should_wait) {
                _ = self.wake.waitTimeout(self.io, clock.timeoutAfterMs(self.scheduled_delay_millis)) catch {};
            }

            self.mutex.lockUncancelable(self.io);
            if (self.queue.len > 0) {
                _ = self.exportBatch();
            }
            self.mutex.unlock(self.io);
        }
    }

    /// Must be called while holding the mutex
    fn exportBatch(self: *Self) bool {
        if (self.queue.len == 0) return false;

        const batch_size = @min(self.queue.len, self.max_export_batch_size);
        if (batch_size == 0) return false;

        const export_spans = self.allocator.alloc(trace.Span, batch_size) catch {
            std.log.err("BatchingProcessor failed to allocate memory for export batch", .{});
            return false;
        };
        defer self.allocator.free(export_spans);

        const spans_to_export = self.queue.popBatch(export_spans);

        // Export the batch (unlock mutex during export)
        self.mutex.unlock(self.io);
        defer self.mutex.lockUncancelable(self.io);
        defer for (export_spans) |*span| {
            span.deinit();
        };

        self.exporter.exportSpans(spans_to_export) catch |err| {
            std.log.err("BatchingProcessor failed to export span batch: {}", .{err});
        };
        return true;
    }

    fn cloneAttributes(
        allocator: std.mem.Allocator,
        source: SpanAttributes,
    ) !SpanAttributes {
        var result: SpanAttributes = .empty;
        errdefer result.deinit(allocator);

        try result.ensureTotalCapacity(allocator, source.count());
        for (source.keys(), source.values()) |key, value| {
            try result.put(allocator, key, value);
        }

        return result;
    }

    fn cloneSpan(allocator: std.mem.Allocator, span: trace.Span) !trace.Span {
        var result = trace.Span.init(allocator, span.span_context, span.name, span.kind, span.scope);
        errdefer result.deinit();

        result.start_time_unix_nano = span.start_time_unix_nano;
        result.end_time_unix_nano = span.end_time_unix_nano;
        result.status = span.status;
        result.is_recording = span.is_recording;

        result.attributes = try cloneAttributes(allocator, span.attributes);

        try result.events.ensureTotalCapacity(allocator, span.events.items.len);
        for (span.events.items) |event| {
            var cloned_event = trace.Span.Event.init(allocator, event.name, event.timestamp);
            errdefer cloned_event.deinit();
            cloned_event.attributes = try cloneAttributes(allocator, event.attributes);
            result.events.appendAssumeCapacity(cloned_event);
        }

        try result.links.ensureTotalCapacity(allocator, span.links.items.len);
        for (span.links.items) |link| {
            var cloned_link = trace.Span.Link.init(allocator, link.span_context);
            errdefer cloned_link.deinit();
            cloned_link.attributes = try cloneAttributes(allocator, link.attributes);
            result.links.appendAssumeCapacity(cloned_link);
        }

        return result;
    }
};

test "SimpleProcessor basic functionality" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Mock exporter
    const MockExporter = struct {
        allocator: std.mem.Allocator,
        exported_spans: std.ArrayList(trace.Span),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return @This(){
                .allocator = alloc,
                .exported_spans = std.ArrayList(trace.Span).empty,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.exported_spans.deinit(self.allocator);
        }

        pub fn exportSpans(ctx: *anyopaque, spans: []trace.Span) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.exported_spans.appendSlice(self.allocator, spans);
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
    var processor = SimpleProcessor.init(allocator, io, exporter);
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
    const io = std.testing.io;

    // Mock exporter (same as above)
    const MockExporter = struct {
        allocator: std.mem.Allocator,
        exported_spans: std.ArrayList(trace.Span),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return @This(){
                .allocator = alloc,
                .exported_spans = std.ArrayList(trace.Span).empty,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.exported_spans.deinit(self.allocator);
        }

        pub fn exportSpans(ctx: *anyopaque, spans: []trace.Span) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.exported_spans.appendSlice(self.allocator, spans);
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
    var processor = try BatchingProcessor.init(allocator, io, exporter, .{
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
    clock.sleep(200 * std.time.ns_per_ms);

    // Force flush to export remaining spans
    try span_processor.forceFlush();

    // Verify spans were exported
    try std.testing.expectEqual(@as(usize, 3), mock_exporter.exported_spans.items.len);
}
