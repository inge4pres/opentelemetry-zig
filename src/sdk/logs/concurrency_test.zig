const std = @import("std");
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const Attribute = @import("../../attributes.zig").Attribute;
const Context = @import("../../api.zig").context.Context;

// Import from the logger_provider.zig file directly
const logger_provider = @import("../../api/logs/logger_provider.zig");
const LoggerProvider = logger_provider.LoggerProvider;
const Logger = logger_provider.Logger;
const ReadWriteLogRecord = logger_provider.ReadWriteLogRecord;
const ReadableLogRecord = logger_provider.ReadableLogRecord;

const enabled_parameters = @import("../../api/logs/enabled_parameters.zig");
const EnabledParameters = enabled_parameters.EnabledParameters;

const LogRecordProcessor = @import("log_record_processor.zig").LogRecordProcessor;
const LogRecordExporter = @import("log_record_exporter.zig").LogRecordExporter;
const SimpleLogRecordProcessor = @import("log_record_processor.zig").SimpleLogRecordProcessor;
const BatchingLogRecordProcessor = @import("log_record_processor.zig").BatchingLogRecordProcessor;

/// Thread-safe counter for tracking operations in concurrent tests
const AtomicCounter = struct {
    value: std.atomic.Value(usize),

    fn init() AtomicCounter {
        return .{ .value = std.atomic.Value(usize).init(0) };
    }

    fn increment(self: *AtomicCounter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    fn get(self: *AtomicCounter) usize {
        return self.value.load(.monotonic);
    }
};

/// Mock processor that counts onEmit calls
const CountingProcessor = struct {
    counter: *AtomicCounter,

    fn init(counter: *AtomicCounter) CountingProcessor {
        return .{ .counter = counter };
    }

    fn onEmit(_: *anyopaque, _: *ReadWriteLogRecord, _: Context) void {
        // Intentionally access counter through global state
        // This will be set up in each test
    }

    fn enabled(_: *anyopaque, _: EnabledParameters) bool {
        return true;
    }

    fn shutdown(_: *anyopaque) anyerror!void {}

    fn forceFlush(_: *anyopaque) anyerror!void {}

    fn asLogRecordProcessor(self: *CountingProcessor) LogRecordProcessor {
        return LogRecordProcessor{
            .ptr = self,
            .vtable = &.{
                .onEmitFn = onEmit,
                .enabledFn = enabled,
                .shutdownFn = shutdown,
                .forceFlushFn = forceFlush,
            },
        };
    }
};

/// Thread-safe mock processor that tracks calls
const MockProcessor = struct {
    allocator: std.mem.Allocator,
    emit_count: std.atomic.Value(usize),
    enabled_count: std.atomic.Value(usize),
    flush_count: std.atomic.Value(usize),
    shutdown_count: std.atomic.Value(usize),
    should_enable: bool,

    fn init(allocator: std.mem.Allocator, should_enable: bool) MockProcessor {
        return .{
            .allocator = allocator,
            .emit_count = std.atomic.Value(usize).init(0),
            .enabled_count = std.atomic.Value(usize).init(0),
            .flush_count = std.atomic.Value(usize).init(0),
            .shutdown_count = std.atomic.Value(usize).init(0),
            .should_enable = should_enable,
        };
    }

    fn onEmit(ctx: *anyopaque, _: *ReadWriteLogRecord, _: Context) void {
        const self: *MockProcessor = @ptrCast(@alignCast(ctx));
        _ = self.emit_count.fetchAdd(1, .monotonic);
    }

    fn enabled(ctx: *anyopaque, _: EnabledParameters) bool {
        const self: *MockProcessor = @ptrCast(@alignCast(ctx));
        _ = self.enabled_count.fetchAdd(1, .monotonic);
        return self.should_enable;
    }

    fn shutdown(ctx: *anyopaque) anyerror!void {
        const self: *MockProcessor = @ptrCast(@alignCast(ctx));
        _ = self.shutdown_count.fetchAdd(1, .monotonic);
    }

    fn forceFlush(ctx: *anyopaque) anyerror!void {
        const self: *MockProcessor = @ptrCast(@alignCast(ctx));
        _ = self.flush_count.fetchAdd(1, .monotonic);
    }

    fn asLogRecordProcessor(self: *MockProcessor) LogRecordProcessor {
        return LogRecordProcessor{
            .ptr = self,
            .vtable = &.{
                .onEmitFn = onEmit,
                .enabledFn = enabled,
                .shutdownFn = shutdown,
                .forceFlushFn = forceFlush,
            },
        };
    }

    fn getEmitCount(self: *MockProcessor) usize {
        return self.emit_count.load(.monotonic);
    }

    fn getEnabledCount(self: *MockProcessor) usize {
        return self.enabled_count.load(.monotonic);
    }

    fn getFlushCount(self: *MockProcessor) usize {
        return self.flush_count.load(.monotonic);
    }

    fn getShutdownCount(self: *MockProcessor) usize {
        return self.shutdown_count.load(.monotonic);
    }
};

// Test helper functions

fn getLoggerWorker(provider: *LoggerProvider, scope: InstrumentationScope, logger_ptr: **Logger) !void {
    const logger = try provider.getLogger(scope);
    logger_ptr.* = logger;
}

fn emitLogWorker(logger: *Logger, count: usize) void {
    for (0..count) |i| {
        const body = std.fmt.allocPrint(std.heap.page_allocator, "Log message {}", .{i}) catch return;
        defer std.heap.page_allocator.free(body);
        logger.emit(null, null, body, &.{});
    }
}

fn shutdownWorker(provider: *LoggerProvider) void {
    provider.shutdown() catch {};
}

fn forceFlushWorker(provider: *LoggerProvider) void {
    provider.forceFlush() catch {};
}

fn enabledWorker(logger: *Logger, count: usize, counter: *AtomicCounter) void {
    for (0..count) |_| {
        if (logger.enabled(.{
            .context = Context.init(),
            .severity = 9,
            .event_name = null,
        })) {
            counter.increment();
        }
    }
}

fn addProcessorWorker(provider: *LoggerProvider, processor: LogRecordProcessor) void {
    // Sleep briefly to let other threads start
    std.Thread.sleep(1 * std.time.ns_per_ms);
    provider.addLogRecordProcessor(processor) catch {};
}

// Tests start here

test "concurrent logger acquisition - same scope" {
    var provider = try LoggerProvider.init(std.testing.allocator, null);
    defer provider.deinit();

    const scope = InstrumentationScope{ .name = "test-scope" };
    const num_threads = 10;
    var threads: [num_threads]std.Thread = undefined;
    var loggers: [num_threads]*Logger = undefined;

    // Spawn threads that all request the same scope
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, getLoggerWorker, .{ provider, scope, &loggers[i] });
    }

    // Wait for all threads
    for (0..num_threads) |i| {
        threads[i].join();
    }

    // Verify all loggers are the same instance (cache correctness)
    const first_logger = loggers[0];
    for (loggers) |logger| {
        try std.testing.expectEqual(first_logger, logger);
    }
}

test "concurrent logger acquisition - different scopes" {
    var provider = try LoggerProvider.init(std.testing.allocator, null);
    defer provider.deinit();

    const num_threads = 10;
    var threads: [num_threads]std.Thread = undefined;
    var loggers: [num_threads]*Logger = undefined;
    var scope_names: [num_threads][]const u8 = undefined;

    // Allocate scope names first
    for (0..num_threads) |i| {
        scope_names[i] = try std.fmt.allocPrint(std.testing.allocator, "scope-{}", .{i});
    }
    defer {
        for (scope_names) |name| {
            std.testing.allocator.free(name);
        }
    }

    // Spawn threads that each request a different scope
    for (0..num_threads) |i| {
        const scope = InstrumentationScope{ .name = scope_names[i] };
        threads[i] = try std.Thread.spawn(.{}, getLoggerWorker, .{ provider, scope, &loggers[i] });
    }

    // Wait for all threads
    for (0..num_threads) |i| {
        threads[i].join();
    }

    // Verify all loggers are different
    for (0..num_threads) |i| {
        for (i + 1..num_threads) |j| {
            try std.testing.expect(loggers[i] != loggers[j]);
        }
    }
}

test "concurrent log emission" {
    var provider = try LoggerProvider.init(std.testing.allocator, null);
    defer provider.deinit();

    var mock_processor = MockProcessor.init(std.testing.allocator, true);
    try provider.addLogRecordProcessor(mock_processor.asLogRecordProcessor());

    const logger = try provider.getLogger(.{ .name = "test-logger" });

    const num_threads = 10;
    const logs_per_thread = 100;
    var threads: [num_threads]std.Thread = undefined;

    // Spawn threads that emit logs concurrently
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, emitLogWorker, .{ logger, logs_per_thread });
    }

    // Wait for all threads
    for (0..num_threads) |i| {
        threads[i].join();
    }

    // Verify all logs were processed
    const expected_count = num_threads * logs_per_thread;
    try std.testing.expectEqual(expected_count, mock_processor.getEmitCount());
}

test "concurrent processor operations" {
    var provider = try LoggerProvider.init(std.testing.allocator, null);
    defer provider.deinit();

    var mock_processor1 = MockProcessor.init(std.testing.allocator, true);
    var mock_processor2 = MockProcessor.init(std.testing.allocator, true);

    try provider.addLogRecordProcessor(mock_processor1.asLogRecordProcessor());

    const logger = try provider.getLogger(.{ .name = "test-logger" });

    const num_emit_threads = 5;
    const logs_per_thread = 50;
    var emit_threads: [num_emit_threads]std.Thread = undefined;

    // Spawn threads that emit logs
    for (0..num_emit_threads) |i| {
        emit_threads[i] = try std.Thread.spawn(.{}, emitLogWorker, .{ logger, logs_per_thread });
    }

    // While emitting, add another processor
    const add_thread = try std.Thread.spawn(.{}, addProcessorWorker, .{ provider, mock_processor2.asLogRecordProcessor() });

    // Wait for all threads
    for (0..num_emit_threads) |i| {
        emit_threads[i].join();
    }
    add_thread.join();

    // Verify both processors received calls (processor2 may have fewer due to timing)
    const total_expected = num_emit_threads * logs_per_thread;
    try std.testing.expectEqual(total_expected, mock_processor1.getEmitCount());
    // mock_processor2 should have some calls, but exact count depends on when it was added
    try std.testing.expect(mock_processor2.getEmitCount() > 0);
}

test "concurrent shutdown" {
    var provider = try LoggerProvider.init(std.testing.allocator, null);
    defer provider.deinit();

    var mock_processor = MockProcessor.init(std.testing.allocator, true);
    try provider.addLogRecordProcessor(mock_processor.asLogRecordProcessor());

    const num_shutdown_threads = 10;
    var shutdown_threads: [num_shutdown_threads]std.Thread = undefined;

    // Spawn multiple threads calling shutdown
    for (0..num_shutdown_threads) |i| {
        shutdown_threads[i] = try std.Thread.spawn(.{}, shutdownWorker, .{provider});
    }

    // Wait for all threads
    for (0..num_shutdown_threads) |i| {
        shutdown_threads[i].join();
    }

    // Verify shutdown was called exactly once on the processor
    try std.testing.expectEqual(1, mock_processor.getShutdownCount());

    // Verify provider is shut down
    try std.testing.expect(provider.is_shutdown.load(.acquire));
}

test "concurrent shutdown with emission" {
    var provider = try LoggerProvider.init(std.testing.allocator, null);
    defer provider.deinit();

    var mock_processor = MockProcessor.init(std.testing.allocator, true);
    try provider.addLogRecordProcessor(mock_processor.asLogRecordProcessor());

    const logger = try provider.getLogger(.{ .name = "test-logger" });

    const num_emit_threads = 5;
    const logs_per_thread = 100;
    var emit_threads: [num_emit_threads]std.Thread = undefined;

    // Spawn threads that emit logs
    for (0..num_emit_threads) |i| {
        emit_threads[i] = try std.Thread.spawn(.{}, emitLogWorker, .{ logger, logs_per_thread });
    }

    // While emitting, shutdown the provider
    std.Thread.sleep(5 * std.time.ns_per_ms); // Let some logs be emitted first
    const shutdown_thread = try std.Thread.spawn(.{}, shutdownWorker, .{provider});

    // Wait for all threads
    for (0..num_emit_threads) |i| {
        emit_threads[i].join();
    }
    shutdown_thread.join();

    // Verify no crashes occurred and shutdown completed
    try std.testing.expect(provider.is_shutdown.load(.acquire));
    try std.testing.expectEqual(1, mock_processor.getShutdownCount());
}

test "concurrent forceFlush" {
    var provider = try LoggerProvider.init(std.testing.allocator, null);
    defer provider.deinit();

    var mock_processor = MockProcessor.init(std.testing.allocator, true);
    try provider.addLogRecordProcessor(mock_processor.asLogRecordProcessor());

    const logger = try provider.getLogger(.{ .name = "test-logger" });

    // Emit some logs first
    for (0..50) |_| {
        logger.emit(null, null, "test log", &.{});
    }

    const num_flush_threads = 10;
    var flush_threads: [num_flush_threads]std.Thread = undefined;

    // Spawn threads that call forceFlush concurrently
    for (0..num_flush_threads) |i| {
        flush_threads[i] = try std.Thread.spawn(.{}, forceFlushWorker, .{provider});
    }

    // Wait for all threads
    for (0..num_flush_threads) |i| {
        flush_threads[i].join();
    }

    // Verify forceFlush was called (exact count may vary due to lock acquisition)
    try std.testing.expect(mock_processor.getFlushCount() >= 1);
}

test "concurrent enabled checks" {
    var provider = try LoggerProvider.init(std.testing.allocator, null);
    defer provider.deinit();

    var mock_processor = MockProcessor.init(std.testing.allocator, true);
    try provider.addLogRecordProcessor(mock_processor.asLogRecordProcessor());

    const logger = try provider.getLogger(.{ .name = "test-logger" });

    const num_threads = 10;
    const checks_per_thread = 100;
    var threads: [num_threads]std.Thread = undefined;
    var counter = AtomicCounter.init();

    // Spawn threads that call enabled() concurrently
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, enabledWorker, .{ logger, checks_per_thread, &counter });
    }

    // Wait for all threads
    for (0..num_threads) |i| {
        threads[i].join();
    }

    // Verify all enabled checks returned true (processor.should_enable = true)
    const expected_count = num_threads * checks_per_thread;
    try std.testing.expectEqual(expected_count, counter.get());
    try std.testing.expectEqual(expected_count, mock_processor.getEnabledCount());
}

test "batching processor concurrency" {
    // Create a mock exporter that counts exported logs
    const MockExporter = struct {
        export_count: std.atomic.Value(usize),

        fn init() @This() {
            return .{ .export_count = std.atomic.Value(usize).init(0) };
        }

        fn exportLogs(ctx: *anyopaque, log_records: []ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.export_count.fetchAdd(log_records.len, .monotonic);
            // Note: BatchingLogRecordProcessor will deinit the log records after export
        }

        fn shutdown(_: *anyopaque) anyerror!void {}

        fn asLogRecordExporter(self: *@This()) LogRecordExporter {
            return LogRecordExporter{
                .ptr = self,
                .vtable = &.{
                    .exportLogsFn = exportLogs,
                    .shutdownFn = shutdown,
                },
            };
        }

        fn getCount(self: *@This()) usize {
            return self.export_count.load(.monotonic);
        }
    };

    var mock_exporter = MockExporter.init();
    var batching_processor = try BatchingLogRecordProcessor.init(
        std.testing.allocator,
        mock_exporter.asLogRecordExporter(),
        .{
            .max_queue_size = 1000,
            .scheduled_delay_millis = 10,
            .export_timeout_millis = 5000,
            .max_export_batch_size = 50,
        },
    );
    defer {
        const processor_interface = batching_processor.asLogRecordProcessor();
        processor_interface.shutdown() catch {};
        batching_processor.deinit();
    }

    var provider = try LoggerProvider.init(std.testing.allocator, null);
    defer provider.deinit();

    try provider.addLogRecordProcessor(batching_processor.asLogRecordProcessor());

    const logger = try provider.getLogger(.{ .name = "test-logger" });

    const num_threads = 10;
    const logs_per_thread = 100;
    var threads: [num_threads]std.Thread = undefined;

    // Spawn threads that emit logs concurrently to batching processor
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, emitLogWorker, .{ logger, logs_per_thread });
    }

    // Wait for all threads
    for (0..num_threads) |i| {
        threads[i].join();
    }

    // Force flush to ensure all logs are exported
    try provider.forceFlush();

    // Wait a bit for export to complete
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Verify all logs were exported
    const expected_count = num_threads * logs_per_thread;
    try std.testing.expectEqual(expected_count, mock_exporter.getCount());
}

test "mixed operations stress test" {
    var provider = try LoggerProvider.init(std.testing.allocator, null);
    defer provider.deinit();

    var mock_processor1 = MockProcessor.init(std.testing.allocator, true);
    var mock_processor2 = MockProcessor.init(std.testing.allocator, true);
    try provider.addLogRecordProcessor(mock_processor1.asLogRecordProcessor());

    const logger1 = try provider.getLogger(.{ .name = "logger-1" });
    const logger2 = try provider.getLogger(.{ .name = "logger-2" });

    // Mixed workload: emit, getLogger, enabled, addProcessor, forceFlush
    const num_emit_threads = 5;
    const num_enabled_threads = 3;
    const num_flush_threads = 2;
    const logs_per_thread = 50;
    const checks_per_thread = 50;

    var emit_threads: [num_emit_threads]std.Thread = undefined;
    var enabled_threads: [num_enabled_threads]std.Thread = undefined;
    var flush_threads: [num_flush_threads]std.Thread = undefined;
    var counter = AtomicCounter.init();

    // Start emit threads
    for (0..num_emit_threads) |i| {
        const logger = if (i % 2 == 0) logger1 else logger2;
        emit_threads[i] = try std.Thread.spawn(.{}, emitLogWorker, .{ logger, logs_per_thread });
    }

    // Start enabled check threads
    for (0..num_enabled_threads) |i| {
        const logger = if (i % 2 == 0) logger1 else logger2;
        enabled_threads[i] = try std.Thread.spawn(.{}, enabledWorker, .{ logger, checks_per_thread, &counter });
    }

    // Start flush threads
    for (0..num_flush_threads) |i| {
        flush_threads[i] = try std.Thread.spawn(.{}, forceFlushWorker, .{provider});
    }

    // Add another processor mid-flight
    std.Thread.sleep(5 * std.time.ns_per_ms);
    const add_thread = try std.Thread.spawn(.{}, addProcessorWorker, .{ provider, mock_processor2.asLogRecordProcessor() });

    // Wait for all threads
    for (0..num_emit_threads) |i| {
        emit_threads[i].join();
    }
    for (0..num_enabled_threads) |i| {
        enabled_threads[i].join();
    }
    for (0..num_flush_threads) |i| {
        flush_threads[i].join();
    }
    add_thread.join();

    // Verify no crashes and reasonable results
    const total_emits = num_emit_threads * logs_per_thread;
    try std.testing.expectEqual(total_emits, mock_processor1.getEmitCount());
    // mock_processor2 may or may not receive calls depending on timing (added mid-flight)
    // Just verify it exists and doesn't crash - actual count is timing-dependent
    try std.testing.expect(mock_processor1.getFlushCount() >= 1);
    try std.testing.expect(counter.get() > 0);
}
