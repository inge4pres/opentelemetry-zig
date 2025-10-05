const std = @import("std");
const logs = @import("../../api/logs/logger_provider.zig");
const context = @import("../../api/context.zig");
const LogRecordExporter = @import("log_record_exporter.zig").LogRecordExporter;

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
};

/// SimpleLogRecordProcessor passes log records to the configured exporter immediately.
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#simple-processor
pub const SimpleLogRecordProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: LogRecordExporter,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, exporter: LogRecordExporter) Self {
        return Self{
            .allocator = allocator,
            .exporter = exporter,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn asLogRecordProcessor(self: *Self) LogRecordProcessor {
        return LogRecordProcessor{
            .ptr = self,
            .vtable = &.{
                .onEmitFn = onEmit,
                .shutdownFn = shutdown,
                .forceFlushFn = forceFlush,
            },
        };
    }

    fn onEmit(ctx: *anyopaque, log_record: *logs.ReadWriteLogRecord, _: context.Context) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.exporter.shutdown();
    }

    fn forceFlush(_: *anyopaque) anyerror!void {
        // SimpleLogRecordProcessor exports immediately, so nothing to flush
        return;
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
    queue: std.ArrayList(logs.ReadableLogRecord),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    export_thread: ?std.Thread,
    should_shutdown: std.atomic.Value(bool),

    const Self = @This();

    pub const Config = struct {
        max_queue_size: usize = 2048,
        scheduled_delay_millis: u64 = 1000,
        export_timeout_millis: u64 = 30000,
        max_export_batch_size: usize = 512,
    };

    pub fn init(allocator: std.mem.Allocator, exporter: LogRecordExporter, config: Config) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .exporter = exporter,
            .max_queue_size = config.max_queue_size,
            .scheduled_delay_millis = config.scheduled_delay_millis,
            .export_timeout_millis = config.export_timeout_millis,
            .max_export_batch_size = config.max_export_batch_size,
            .queue = std.ArrayList(logs.ReadableLogRecord).init(allocator),
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

        // Clean up any remaining log records
        for (self.queue.items) |log_record| {
            log_record.deinit(self.allocator);
        }
        self.queue.deinit();
        self.allocator.destroy(self);
    }

    pub fn asLogRecordProcessor(self: *Self) LogRecordProcessor {
        return LogRecordProcessor{
            .ptr = self,
            .vtable = &.{
                .onEmitFn = onEmit,
                .shutdownFn = shutdown,
                .forceFlushFn = forceFlush,
            },
        };
    }

    fn onEmit(ctx: *anyopaque, log_record: *logs.ReadWriteLogRecord, _: context.Context) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        // If queue is full, drop the log record
        if (self.queue.items.len >= self.max_queue_size) {
            std.log.warn("BatchingLogRecordProcessor queue full, dropping log record", .{});
            return;
        }

        // Convert to readable and add to queue
        const readable = log_record.toReadable(self.allocator) catch |err| {
            std.log.err("BatchingLogRecordProcessor failed to convert log record: {}", .{err});
            return;
        };

        self.queue.append(readable) catch {
            std.log.err("BatchingLogRecordProcessor failed to add log record to queue", .{});
            readable.deinit(self.allocator);
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

        // Export all pending log records
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

            // Export if we have log records or if shutting down
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
        const logs_to_export = self.queue.items[0..batch_size];

        // Make a copy of the log records to export
        const export_logs = self.allocator.alloc(logs.ReadableLogRecord, batch_size) catch {
            std.log.err("BatchingLogRecordProcessor failed to allocate memory for export batch", .{});
            return;
        };
        defer self.allocator.free(export_logs);

        @memcpy(export_logs, logs_to_export);

        // Remove exported log records from queue
        std.mem.copyForwards(logs.ReadableLogRecord, self.queue.items, self.queue.items[batch_size..]);

        // Deinit the exported records before shrinking
        for (export_logs) |log_record| {
            log_record.deinit(self.allocator);
        }

        self.queue.shrinkRetainingCapacity(self.queue.items.len - batch_size);

        // Export the batch (unlock mutex during export)
        self.mutex.unlock();
        defer self.mutex.lock();

        self.exporter.exportLogs(export_logs) catch |err| {
            std.log.err("BatchingLogRecordProcessor failed to export log batch: {}", .{err});
        };
    }
};

test "SimpleLogRecordProcessor basic functionality" {
    const allocator = std.testing.allocator;
    const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

    // Mock exporter
    const MockExporter = struct {
        exported_logs: std.ArrayList(logs.ReadableLogRecord),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return @This(){
                .exported_logs = std.ArrayList(logs.ReadableLogRecord).init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            for (self.exported_logs.items) |log_record| {
                log_record.deinit(self.exported_logs.allocator);
            }
            self.exported_logs.deinit();
        }

        pub fn exportLogs(ctx: *anyopaque, log_records: []logs.ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (log_records) |log_record| {
                // Make a copy since we're storing it
                const attrs = try self.exported_logs.allocator.alloc(@import("../../attributes.zig").Attribute, log_record.attributes.len);
                @memcpy(attrs, log_record.attributes);

                try self.exported_logs.append(.{
                    .timestamp = log_record.timestamp,
                    .observed_timestamp = log_record.observed_timestamp,
                    .trace_id = log_record.trace_id,
                    .span_id = log_record.span_id,
                    .severity_number = log_record.severity_number,
                    .severity_text = log_record.severity_text,
                    .body = log_record.body,
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
    var processor = SimpleLogRecordProcessor.init(allocator, exporter);
    const log_processor = processor.asLogRecordProcessor();

    // Create a test log record
    const scope = InstrumentationScope{ .name = "test-logger" };
    var log_record = logs.ReadWriteLogRecord.init(allocator, scope);
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
    const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
    const Attribute = @import("../../attributes.zig").Attribute;

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
    var processor = SimpleLogRecordProcessor.init(allocator, exporter);
    const log_processor = processor.asLogRecordProcessor();

    // Create a test log record with attributes
    const scope = InstrumentationScope{ .name = "test-logger" };
    var log_record = logs.ReadWriteLogRecord.init(allocator, scope);
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
    const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

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

    var processor = try BatchingLogRecordProcessor.init(allocator, exporter, .{
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
        var log_record = logs.ReadWriteLogRecord.init(allocator, scope);
        defer log_record.deinit(allocator);

        log_record.body = "test log message";
        log_record.severity_number = 9;

        log_processor.onEmit(&log_record, ctx);
    }

    // Wait a bit for the background thread to process
    std.time.sleep(200 * std.time.ns_per_ms);

    // Force flush to export remaining log records
    try log_processor.forceFlush();

    // Verify log records were exported (at least one batch)
    const export_count = mock_exporter.export_count.load(.monotonic);
    try std.testing.expect(export_count > 0);
}

test "integration: multiple processors in pipeline" {
    const allocator = std.testing.allocator;
    const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
    const Attribute = @import("../../attributes.zig").Attribute;

    // Track which processors were called and in what order
    var call_order = std.ArrayList(u8).init(allocator);
    defer call_order.deinit();

    // First processor - adds an attribute
    const FirstProcessor = struct {
        order: *std.ArrayList(u8),

        pub fn onEmit(ctx: *anyopaque, log_record: *logs.ReadWriteLogRecord, _: context.Context) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.order.append(1) catch {};

            // Add an attribute
            const attr = Attribute{ .key = "processor.first", .value = .{ .bool = true } };
            log_record.setAttribute(self.order.allocator, attr) catch {};
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}
        pub fn forceFlush(_: *anyopaque) anyerror!void {}

        pub fn asLogRecordProcessor(self: *@This()) LogRecordProcessor {
            return LogRecordProcessor{
                .ptr = self,
                .vtable = &.{
                    .onEmitFn = onEmit,
                    .shutdownFn = shutdown,
                    .forceFlushFn = forceFlush,
                },
            };
        }
    };

    // Second processor - modifies severity
    const SecondProcessor = struct {
        order: *std.ArrayList(u8),

        pub fn onEmit(ctx: *anyopaque, log_record: *logs.ReadWriteLogRecord, _: context.Context) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.order.append(2) catch {};

            // Verify first processor's attribute is visible
            std.debug.assert(log_record.attributes.items.len > 0);

            // Modify severity
            log_record.severity_number = 17; // ERROR
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}
        pub fn forceFlush(_: *anyopaque) anyerror!void {}

        pub fn asLogRecordProcessor(self: *@This()) LogRecordProcessor {
            return LogRecordProcessor{
                .ptr = self,
                .vtable = &.{
                    .onEmitFn = onEmit,
                    .shutdownFn = shutdown,
                    .forceFlushFn = forceFlush,
                },
            };
        }
    };

    var first = FirstProcessor{ .order = &call_order };
    var second = SecondProcessor{ .order = &call_order };

    const first_processor = first.asLogRecordProcessor();
    const second_processor = second.asLogRecordProcessor();

    // Create a log record
    const scope = InstrumentationScope{ .name = "test-logger" };
    var log_record = logs.ReadWriteLogRecord.init(allocator, scope);
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