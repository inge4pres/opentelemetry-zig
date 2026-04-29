const std = @import("std");
const clock = @import("clock");
const logs = @import("../../api/logs/logger_provider.zig");
const context = @import("../../api/context.zig");
const LogRecordExporter = @import("log_record_exporter.zig").LogRecordExporter;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const Attribute = @import("../../attributes.zig").Attribute;
const EnabledParameters = @import("../../api/logs/enabled_parameters.zig").EnabledParameters;

const LogRecordQueue = struct {
    buffer: []logs.ReadableLogRecord = &.{},
    head: usize = 0,
    len: usize = 0,

    fn init(allocator: std.mem.Allocator, capacity: usize) !LogRecordQueue {
        return .{ .buffer = try allocator.alloc(logs.ReadableLogRecord, capacity) };
    }

    fn deinit(self: *LogRecordQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.* = .{};
    }

    fn deinitItems(self: *LogRecordQueue, allocator: std.mem.Allocator) void {
        for (0..self.len) |i| {
            const index = (self.head + i) % self.buffer.len;
            self.buffer[index].deinit(allocator);
        }
    }

    fn push(self: *LogRecordQueue, log_record: logs.ReadableLogRecord) bool {
        if (self.len >= self.buffer.len) return false;
        const index = (self.head + self.len) % self.buffer.len;
        self.buffer[index] = log_record;
        self.len += 1;
        return true;
    }

    fn popBatch(self: *LogRecordQueue, dest: []logs.ReadableLogRecord) []logs.ReadableLogRecord {
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

/// LogRecordProcessor is an interface which allows hooks for LogRecord emitting.
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#logrecordprocessor
pub const LogRecordProcessor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    pub const VTable = struct {
        /// onEmit is called synchronously when a LogRecord is emitted.
        /// This method MUST NOT block and MUST NOT throw exceptions.
        /// The LogRecord can be modified, and mutations are visible to subsequent processors.
        onEmitFn: *const fn (ctx: *anyopaque, log_record: *logs.ReadWriteLogRecord, parent_context: context.Context) void,

        /// shutdown is called when the SDK is shut down.
        /// Should complete within a timeout and includes the effect of forceFlush.
        shutdownFn: *const fn (ctx: *anyopaque) anyerror!void,

        /// forceFlush ensures completion of pending LogRecord tasks.
        /// Should prioritize honoring the specified timeout.
        forceFlushFn: *const fn (ctx: *anyopaque) anyerror!void,

        /// enabled checks if this processor would process a log record with the given parameters.
        /// Implementations should default to returning true when uncertain.
        /// This method MUST be safe to call concurrently.
        enabledFn: *const fn (ctx: *anyopaque, params: EnabledParameters) bool,
    };

    /// Called when a log record is emitted
    pub fn onEmit(self: Self, log_record: *logs.ReadWriteLogRecord, parent_context: context.Context) void {
        return self.vtable.onEmitFn(self.ptr, log_record, parent_context);
    }

    /// Shuts down the processor
    pub fn shutdown(self: Self) anyerror!void {
        return self.vtable.shutdownFn(self.ptr);
    }

    /// Forces a flush of any buffered log records
    pub fn forceFlush(self: Self) anyerror!void {
        return self.vtable.forceFlushFn(self.ptr);
    }

    /// Check if this processor would process a log record with the given parameters
    pub fn enabled(self: Self, params: EnabledParameters) bool {
        return self.vtable.enabledFn(self.ptr, params);
    }
};

/// SimpleLogRecordProcessor passes log records to the configured exporter immediately.
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#simple-processor
pub const SimpleLogRecordProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: LogRecordExporter,
    mutex: std.Io.Mutex,
    io: std.Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, exporter: LogRecordExporter) Self {
        return Self{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = std.Io.Mutex.init,
            .io = io,
        };
    }

    pub fn asLogRecordProcessor(self: *Self) LogRecordProcessor {
        return LogRecordProcessor{
            .ptr = self,
            .vtable = &.{
                .onEmitFn = onEmit,
                .shutdownFn = shutdown,
                .forceFlushFn = forceFlush,
                .enabledFn = enabled,
            },
        };
    }

    fn onEmit(ctx: *anyopaque, log_record: *logs.ReadWriteLogRecord, _: context.Context) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Convert to readable and export immediately
        const readable = log_record.toReadable(self.allocator) catch |err| {
            std.log.err("SimpleLogRecordProcessor failed to convert log record: {}", .{err});
            return;
        };
        defer readable.deinit(self.allocator);

        var log_records = [_]logs.ReadableLogRecord{readable};
        self.exporter.exportLogs(log_records[0..]) catch |err| {
            std.log.err("SimpleLogRecordProcessor failed to export log record: {}", .{err});
        };
    }

    fn shutdown(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.exporter.shutdown();
    }

    fn forceFlush(_: *anyopaque) anyerror!void {
        // SimpleLogRecordProcessor exports immediately, so nothing to flush
        return;
    }

    fn enabled(ctx: *anyopaque, params: EnabledParameters) bool {
        _ = ctx;
        _ = params;
        return true;
    }
};

/// BatchingLogRecordProcessor batches log records and passes them to the configured exporter.
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#batching-processor
pub const BatchingLogRecordProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: LogRecordExporter,

    // Configuration
    max_queue_size: usize,
    scheduled_delay_millis: u64,
    export_timeout_millis: u64,
    max_export_batch_size: usize,

    // State
    queue: LogRecordQueue,
    mutex: std.Io.Mutex,
    wake: std.Io.Event,
    io: std.Io,
    export_task: ?std.Io.Future(void),
    should_shutdown: std.atomic.Value(bool),

    const Self = @This();

    pub const Config = struct {
        max_queue_size: usize = 2048,
        scheduled_delay_millis: u64 = 1000,
        export_timeout_millis: u64 = 30000,
        max_export_batch_size: usize = 512,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, exporter: LogRecordExporter, config: Config) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const max_export_batch_size = if (config.max_queue_size == 0)
            0
        else
            @max(@as(usize, 1), @min(config.max_export_batch_size, config.max_queue_size));
        var queue = try LogRecordQueue.init(allocator, config.max_queue_size);
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

        self.queue.deinitItems(self.allocator);
        self.queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn asLogRecordProcessor(self: *Self) LogRecordProcessor {
        return LogRecordProcessor{
            .ptr = self,
            .vtable = &.{
                .onEmitFn = onEmit,
                .shutdownFn = shutdown,
                .forceFlushFn = forceFlush,
                .enabledFn = enabled,
            },
        };
    }

    fn onEmit(ctx: *anyopaque, log_record: *logs.ReadWriteLogRecord, _: context.Context) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // If queue is full, drop the log record
        if (self.queue.len >= self.max_queue_size) {
            std.log.warn("BatchingLogRecordProcessor queue full, dropping log record", .{});
            return;
        }

        // Convert to readable and add to queue
        const readable = log_record.toReadable(self.allocator) catch |err| {
            std.log.err("BatchingLogRecordProcessor failed to convert log record: {}", .{err});
            return;
        };

        if (!self.queue.push(readable)) {
            std.log.err("BatchingLogRecordProcessor failed to add log record to queue", .{});
            readable.deinit(self.allocator);
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

        // Export all pending log records
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
            // Resetting unconditionally races with onEmit: if onEmit fires
            // wake.set() between the previous iteration's unlock and the
            // reset below, the signal is lost and we block for the full
            // scheduled_delay_millis even though a batch is queued.
            // When max_export_batch_size == 0 (e.g. max_queue_size == 0 via
            // OTEL_BLRP_MAX_QUEUE_SIZE=0) the naive `len < batch` comparison
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

        const export_logs = self.allocator.alloc(logs.ReadableLogRecord, batch_size) catch {
            std.log.err("BatchingLogRecordProcessor failed to allocate memory for export batch", .{});
            return false;
        };
        defer self.allocator.free(export_logs);

        const logs_to_export = self.queue.popBatch(export_logs);

        // Export the batch (unlock mutex during export)
        self.mutex.unlock(self.io);
        defer self.mutex.lockUncancelable(self.io);
        defer for (export_logs) |log_record| {
            log_record.deinit(self.allocator);
        };

        self.exporter.exportLogs(logs_to_export) catch |err| {
            std.log.err("BatchingLogRecordProcessor failed to export log batch: {}", .{err});
        };
        return true;
    }

    fn enabled(ctx: *anyopaque, params: EnabledParameters) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = params;

        // Not enabled if shutting down
        if (self.should_shutdown.load(.acquire)) {
            return false;
        }

        // Default to true per spec (even if queue might be full)
        return true;
    }
};

test "SimpleLogRecordProcessor basic functionality" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Mock exporter
    const MockExporter = struct {
        allocator: std.mem.Allocator,
        exported_logs: std.ArrayList(logs.ReadableLogRecord),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return @This(){
                .allocator = alloc,
                .exported_logs = .empty,
            };
        }

        pub fn deinit(self: *@This()) void {
            for (self.exported_logs.items) |log_record| {
                log_record.deinit(self.allocator);
            }
            self.exported_logs.deinit(self.allocator);
        }

        pub fn exportLogs(ctx: *anyopaque, log_records: []logs.ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (log_records) |log_record| {
                // Make a copy since we're storing it
                const attrs = try self.allocator.alloc(@import("../../attributes.zig").Attribute, log_record.attributes.len);
                @memcpy(attrs, log_record.attributes);

                // Copy severity_text and body strings since they will be freed after export
                const severity_text = if (log_record.severity_text) |text|
                    try self.allocator.dupe(u8, text)
                else
                    null;

                const body = if (log_record.body) |b|
                    try self.allocator.dupe(u8, b)
                else
                    null;

                try self.exported_logs.append(self.allocator, .{
                    .timestamp = log_record.timestamp,
                    .observed_timestamp = log_record.observed_timestamp,
                    .trace_id = log_record.trace_id,
                    .span_id = log_record.span_id,
                    .severity_number = log_record.severity_number,
                    .severity_text = severity_text,
                    .body = body,
                    .attributes = attrs,
                    .resource = log_record.resource,
                    .scope = log_record.scope,
                });
            }
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}

        pub fn asLogRecordExporter(self: *@This()) LogRecordExporter {
            return LogRecordExporter{
                .ptr = self,
                .vtable = &.{
                    .exportLogsFn = exportLogs,
                    .shutdownFn = shutdown,
                },
            };
        }
    };

    var mock_exporter = MockExporter.init(allocator);
    defer mock_exporter.deinit();

    const exporter = mock_exporter.asLogRecordExporter();
    var processor = SimpleLogRecordProcessor.init(allocator, io, exporter);
    const log_processor = processor.asLogRecordProcessor();

    // Create a test log record
    const scope = InstrumentationScope{ .name = "test-logger" };
    var log_record = logs.ReadWriteLogRecord.init(scope);
    defer log_record.deinit(allocator);

    log_record.body = "test log message";
    log_record.severity_number = 9; // Info

    const ctx = context.Context.init();

    // Test onEmit
    log_processor.onEmit(&log_record, ctx);

    // Verify the log was exported
    try std.testing.expectEqual(@as(usize, 1), mock_exporter.exported_logs.items.len);
    try std.testing.expectEqualStrings("test log message", mock_exporter.exported_logs.items[0].body.?);
    try std.testing.expectEqual(@as(u8, 9), mock_exporter.exported_logs.items[0].severity_number.?);
}

test "SimpleLogRecordProcessor with attributes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Mock exporter (simplified for this test)
    const MockExporter = struct {
        export_count: usize = 0,

        pub fn exportLogs(ctx: *anyopaque, _: []logs.ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.export_count += 1;
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}

        pub fn asLogRecordExporter(self: *@This()) LogRecordExporter {
            return LogRecordExporter{
                .ptr = self,
                .vtable = &.{
                    .exportLogsFn = exportLogs,
                    .shutdownFn = shutdown,
                },
            };
        }
    };

    var mock_exporter = MockExporter{};
    const exporter = mock_exporter.asLogRecordExporter();
    var processor = SimpleLogRecordProcessor.init(allocator, io, exporter);
    const log_processor = processor.asLogRecordProcessor();

    // Create a test log record with attributes
    const scope = InstrumentationScope{ .name = "test-logger" };
    var log_record = logs.ReadWriteLogRecord.init(scope);
    defer log_record.deinit(allocator);

    const attr = Attribute{ .key = "test.key", .value = .{ .string = "test.value" } };
    try log_record.setAttribute(allocator, attr);

    log_record.body = "log with attributes";

    const ctx = context.Context.init();

    // Test onEmit
    log_processor.onEmit(&log_record, ctx);

    // Verify export was called
    try std.testing.expectEqual(@as(usize, 1), mock_exporter.export_count);
}

test "BatchingLogRecordProcessor basic functionality" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Mock exporter (simplified)
    const MockExporter = struct {
        export_count: std.atomic.Value(usize),

        pub fn init() @This() {
            return @This(){
                .export_count = std.atomic.Value(usize).init(0),
            };
        }

        pub fn exportLogs(ctx: *anyopaque, _: []logs.ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.export_count.fetchAdd(1, .monotonic);
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}

        pub fn asLogRecordExporter(self: *@This()) LogRecordExporter {
            return LogRecordExporter{
                .ptr = self,
                .vtable = &.{
                    .exportLogsFn = exportLogs,
                    .shutdownFn = shutdown,
                },
            };
        }
    };

    var mock_exporter = MockExporter.init();
    const exporter = mock_exporter.asLogRecordExporter();

    var processor = try BatchingLogRecordProcessor.init(allocator, io, exporter, .{
        .max_export_batch_size = 2, // Small batch size for testing
        .scheduled_delay_millis = 100, // Short delay for testing
    });
    defer {
        const log_processor = processor.asLogRecordProcessor();
        log_processor.shutdown() catch {};
        processor.deinit();
    }

    const log_processor = processor.asLogRecordProcessor();
    const ctx = context.Context.init();

    // Create test log records
    const scope = InstrumentationScope{ .name = "test-logger" };

    // Add 3 log records - should trigger export when batch size (2) is reached
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var log_record = logs.ReadWriteLogRecord.init(scope);
        defer log_record.deinit(allocator);

        log_record.body = "test log message";
        log_record.severity_number = 9;

        log_processor.onEmit(&log_record, ctx);
    }

    // Wait a bit for the background thread to process
    clock.sleep(200 * std.time.ns_per_ms);

    // Force flush to export remaining log records
    try log_processor.forceFlush();

    // Verify log records were exported (at least one batch)
    const export_count = mock_exporter.export_count.load(.monotonic);
    try std.testing.expect(export_count > 0);
}

test "integration: multiple processors in pipeline" {
    const allocator = std.testing.allocator;

    // Track which processors were called and in what order
    var call_order: std.ArrayList(u8) = .empty;
    defer call_order.deinit(allocator);

    // First processor - adds an attribute
    const FirstProcessor = struct {
        allocator: std.mem.Allocator,
        order: *std.ArrayList(u8),

        pub fn onEmit(ctx: *anyopaque, log_record: *logs.ReadWriteLogRecord, _: context.Context) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.order.append(self.allocator, 1) catch {};

            // Add an attribute
            const attr = Attribute{ .key = "processor.first", .value = .{ .bool = true } };
            log_record.setAttribute(self.allocator, attr) catch {};
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}
        pub fn forceFlush(_: *anyopaque) anyerror!void {}
        pub fn enabled(_: *anyopaque, _: EnabledParameters) bool {
            return true;
        }

        pub fn asLogRecordProcessor(self: *@This()) LogRecordProcessor {
            return LogRecordProcessor{
                .ptr = self,
                .vtable = &.{
                    .onEmitFn = onEmit,
                    .shutdownFn = shutdown,
                    .forceFlushFn = forceFlush,
                    .enabledFn = enabled,
                },
            };
        }
    };

    // Second processor - modifies severity
    const SecondProcessor = struct {
        allocator: std.mem.Allocator,
        order: *std.ArrayList(u8),

        pub fn onEmit(ctx: *anyopaque, log_record: *logs.ReadWriteLogRecord, _: context.Context) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.order.append(self.allocator, 2) catch {};

            // Verify first processor's attribute is visible
            std.debug.assert(log_record.attributes.items.len > 0);

            // Modify severity
            log_record.severity_number = 17; // ERROR
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}
        pub fn forceFlush(_: *anyopaque) anyerror!void {}
        pub fn enabled(_: *anyopaque, _: EnabledParameters) bool {
            return true;
        }

        pub fn asLogRecordProcessor(self: *@This()) LogRecordProcessor {
            return LogRecordProcessor{
                .ptr = self,
                .vtable = &.{
                    .onEmitFn = onEmit,
                    .shutdownFn = shutdown,
                    .forceFlushFn = forceFlush,
                    .enabledFn = enabled,
                },
            };
        }
    };

    var first = FirstProcessor{ .allocator = allocator, .order = &call_order };
    var second = SecondProcessor{ .allocator = allocator, .order = &call_order };

    const first_processor = first.asLogRecordProcessor();
    const second_processor = second.asLogRecordProcessor();

    // Create a log record
    const scope = InstrumentationScope{ .name = "test-logger" };
    var log_record = logs.ReadWriteLogRecord.init(scope);
    defer log_record.deinit(allocator);

    log_record.body = "test message";
    log_record.severity_number = 9; // INFO

    const ctx = context.Context.init();

    // Call processors in order
    first_processor.onEmit(&log_record, ctx);
    second_processor.onEmit(&log_record, ctx);

    // Verify processors were called in order
    try std.testing.expectEqual(@as(usize, 2), call_order.items.len);
    try std.testing.expectEqual(@as(u8, 1), call_order.items[0]);
    try std.testing.expectEqual(@as(u8, 2), call_order.items[1]);

    // Verify mutations are visible
    try std.testing.expectEqual(@as(usize, 1), log_record.attributes.items.len);
    try std.testing.expectEqualStrings("processor.first", log_record.attributes.items[0].key);
    try std.testing.expectEqual(@as(u8, 17), log_record.severity_number.?); // Modified by second processor
}
