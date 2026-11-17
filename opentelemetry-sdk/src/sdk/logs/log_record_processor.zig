const std = @import("std");
const clock = @import("timeout");
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

    fn push(self: *LogRecordQueue, log_record: logs.ReadableLogRecord) bool {
        if (self.len >= self.buffer.len) return false;
        const index = (self.head + self.len) % self.buffer.len;
        self.buffer[index] = log_record;
        self.len += 1;
        return true;
    }

    fn popBatch(self: *LogRecordQueue, dest: []logs.ReadableLogRecord) []logs.ReadableLogRecord {
        const count = @min(dest.len, self.len);
        const splitpoint = self.buffer.len - self.head;
        if (count <= splitpoint) {
            @memcpy(dest[0..count], self.buffer[self.head..][0..count]);
        } else {
            @memcpy(dest[0..splitpoint], self.buffer[self.head..]);
            @memcpy(dest[splitpoint..count], self.buffer[0 .. count - splitpoint]);
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
    exporter: LogRecordExporter,
    mutex: std.Io.Mutex,
    io: std.Io,

    const Self = @This();

    pub fn init(io: std.Io, exporter: LogRecordExporter) Self {
        return Self{
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

        var log_records = [_]logs.ReadableLogRecord{log_record.asReadable()};
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

/// The size of the batches to export `count` records in the fewest batches of at most `max`
/// records: spread evenly, instead of full batches followed by a tiny one (513 records are
/// exported as 257 + 256, not 512 + 1). The last batch may be smaller by a few records.
fn evenBatchSize(count: usize, max: usize) usize {
    std.debug.assert(count > 0 and max > 0);
    const batches = (count + max - 1) / max;
    return (count + batches - 1) / batches;
}

/// BatchingLogRecordProcessor batches log records and passes them to the configured exporter.
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#batching-processor
///
/// The processor never calls the exporter concurrently, but that guarantee is per processor:
/// an exporter instance must belong to a single processor.
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
    /// The data of queued records lives in the active arena. An export makes the other arena the
    /// active one, and resets this one once all the records queued in it have been exported.
    arenas: [2]std.heap.ArenaAllocator,
    active_arena: u1,
    /// Holds the batch being exported. Only touched by the caller that is exporting.
    batch_buffer: []logs.ReadableLogRecord,
    mutex: std.Io.Mutex,
    wake: std.Io.Event,
    io: std.Io,
    export_task: ?std.Io.Future(void),
    should_shutdown: std.atomic.Value(bool),
    /// True while a batch is being exported. The exporter's `Export` must never be called
    /// concurrently, so `exportQueued` waits on `export_done` until it is false. Guarded by `mutex`.
    exporting: bool,
    export_done: std.Io.Condition,

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
        const batch_buffer = try allocator.alloc(logs.ReadableLogRecord, max_export_batch_size);
        errdefer allocator.free(batch_buffer);

        self.* = Self{
            .allocator = allocator,
            .exporter = exporter,
            .max_queue_size = config.max_queue_size,
            .scheduled_delay_millis = config.scheduled_delay_millis,
            .export_timeout_millis = config.export_timeout_millis,
            .max_export_batch_size = max_export_batch_size,
            .queue = queue,
            .arenas = .{ .init(allocator), .init(allocator) },
            .active_arena = 0,
            .batch_buffer = batch_buffer,
            .mutex = std.Io.Mutex.init,
            .wake = .unset,
            .io = io,
            .export_task = null,
            .should_shutdown = std.atomic.Value(bool).init(false),
            .exporting = false,
            .export_done = .init,
        };

        // Start the background export task using io.concurrent
        self.export_task = try io.concurrent(exportLoop, .{self});

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Shutdown should have been called before deinit
        std.debug.assert(self.export_task == null);

        self.queue.deinit(self.allocator);
        self.allocator.free(self.batch_buffer);
        for (&self.arenas) |*arena| arena.deinit();
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

        // Deep-copy into the batch arena and enqueue
        const readable = log_record.toReadable(self.arenas[self.active_arena].allocator()) catch |err| {
            std.log.err("BatchingLogRecordProcessor failed to convert log record: {}", .{err});
            return;
        };

        if (!self.queue.push(readable)) {
            std.log.err("BatchingLogRecordProcessor failed to add log record to queue", .{});
            return;
        }

        // Check if we should trigger an export
        if (self.queue.len >= self.max_export_batch_size) {
            self.wake.set(self.io);
        }
    }

    fn shutdown(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Apply the mutex, so a wake cannot arrive between exportLoop's shutdown check and wake.reset().
        self.mutex.lockUncancelable(self.io);
        self.should_shutdown.store(true, .release);
        self.wake.set(self.io);
        self.mutex.unlock(self.io);

        // Wait instead of cancelling: a pending cancellation is delivered downstream
        // inside the final export, dropping it.
        if (self.export_task) |*task| {
            task.await(self.io);
            self.export_task = null;
        }
    }

    fn forceFlush(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Waits for an export in flight, then exports every record queued before this call.
        self.exportQueued();
    }

    fn exportLoop(self: *Self) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.should_shutdown.load(.acquire)) {
                self.exportQueued();
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
            self.exportQueued();
            self.mutex.unlock(self.io);
        }
    }

    /// Exports every record queued when called, in batches of at most `max_export_batch_size`,
    /// of similar sizes (see `evenBatchSize`).
    ///
    /// Must be called while holding the mutex, which is released while exporting. At most one
    /// export runs at a time: a concurrent caller waits for the one in flight, then exports what
    /// is queued by then.
    fn exportQueued(self: *Self) void {
        while (self.exporting) self.export_done.waitUncancelable(self.io, &self.mutex);

        // Records queued from now on are not exported here, and go to the other arena.
        var remaining = self.queue.len;
        if (remaining == 0) return;
        const exported_arena = &self.arenas[self.active_arena];
        self.active_arena +%= 1;
        self.exporting = true;

        const batch_size = evenBatchSize(remaining, self.batch_buffer.len);
        while (remaining > 0) {
            const batch = self.queue.popBatch(self.batch_buffer[0..@min(remaining, batch_size)]);
            remaining -= batch.len;

            // Unlock while exporting to allow concurrent onEmit calls
            self.mutex.unlock(self.io);
            clock.callTimeout(
                self.io,
                self.export_timeout_millis,
                LogRecordExporter.exportLogs,
                .{ self.exporter, batch },
            ) catch |err| {
                std.log.err("BatchingLogRecordProcessor failed to export log batch: {}", .{err});
            };
            self.mutex.lockUncancelable(self.io);
        }

        // Every record that was in this arena has been exported, and no new one was added to it.
        _ = exported_arena.reset(.retain_capacity);
        self.exporting = false;
        self.export_done.broadcast(self.io);
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
            self.exported_logs.deinit(self.allocator);
        }

        pub fn exportLogs(ctx: *anyopaque, log_records: []logs.ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (log_records) |log_record| {
                try self.exported_logs.append(self.allocator, log_record);
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
    var processor = SimpleLogRecordProcessor.init(io, exporter);
    const log_processor = processor.asLogRecordProcessor();

    // Create a test log record
    const scope = InstrumentationScope{ .name = "test-logger" };
    var log_record: logs.ReadWriteLogRecord = .{
        .scope = scope,
        .observed_timestamp = 0,
        .body = .{ .string = "test log message" },
        .severity_number = 9,
    };
    defer log_record.deinit(allocator);

    const ctx = context.Context.init();

    // Test onEmit
    log_processor.onEmit(&log_record, ctx);

    // Verify the log was exported
    try std.testing.expectEqual(@as(usize, 1), mock_exporter.exported_logs.items.len);
    try std.testing.expectEqualStrings("test log message", mock_exporter.exported_logs.items[0].body.?.string);
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
    var processor = SimpleLogRecordProcessor.init(io, exporter);
    const log_processor = processor.asLogRecordProcessor();

    // Create a test log record with attributes
    const scope: InstrumentationScope = .{ .name = "test-logger" };
    var log_record: logs.ReadWriteLogRecord = .{
        .scope = scope,
        .observed_timestamp = 0,
        .body = .{ .string = "log with attributes" },
    };
    defer log_record.deinit(allocator);

    const attr: Attribute = .{ .key = "test.key", .value = .{ .string = "test.value" } };
    try log_record.setAttribute(allocator, attr);

    const ctx = context.Context.init();

    // Test onEmit
    log_processor.onEmit(&log_record, ctx);

    // Verify export was called
    try std.testing.expectEqual(@as(usize, 1), mock_exporter.export_count);
}

test "BatchingLogRecordProcessor bounds export with export_timeout_millis" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Blocks far past the processor's export timeout, on a cancelable sleep so
    // that the timeout can actually cut the export short.
    const StallingExporter = struct {
        io: std.Io,
        canceled: std.atomic.Value(bool) = .init(false),

        pub fn exportLogs(ctx: *anyopaque, _: []logs.ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.Io.sleep(self.io, std.Io.Duration.fromSeconds(5), .awake) catch |err| {
                self.canceled.store(true, .release);
                return err;
            };
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

    var stalling = StallingExporter{ .io = io };
    var processor = try BatchingLogRecordProcessor.init(allocator, io, stalling.asLogRecordExporter(), .{
        .export_timeout_millis = 100,
        // Keep the background loop asleep so forceFlush is what drives the export.
        .scheduled_delay_millis = 60_000,
    });
    defer {
        const log_processor = processor.asLogRecordProcessor();
        log_processor.shutdown() catch {};
        processor.deinit();
    }

    const log_processor = processor.asLogRecordProcessor();
    var log_record: logs.ReadWriteLogRecord = .{
        .scope = InstrumentationScope{ .name = "test-logger" },
        .observed_timestamp = 0,
        .body = .{ .string = "stalled log message" },
        .severity_number = 9,
    };
    defer log_record.deinit(allocator);
    log_processor.onEmit(&log_record, context.Context.init());

    const start_ns: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    try log_processor.forceFlush();
    const elapsed_ms = (@as(u64, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns) / std.time.ns_per_ms;

    try std.testing.expect(stalling.canceled.load(.acquire));
    // The exporter would have blocked for 5s; the deadline is 100ms.
    try std.testing.expect(elapsed_ms < 2000);
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
        var log_record: logs.ReadWriteLogRecord = .{
            .scope = scope,
            .observed_timestamp = 0,
            .body = .{ .string = "test log message" },
            .severity_number = 9,
        };
        defer log_record.deinit(allocator);

        log_processor.onEmit(&log_record, ctx);
    }

    // Wait a bit for the background thread to process
    std.Io.sleep(std.testing.io, .fromNanoseconds(200 * std.time.ns_per_ms), .awake) catch {};

    // Force flush to export remaining log records
    try log_processor.forceFlush();

    // Verify log records were exported (at least one batch)
    const export_count = mock_exporter.export_count.load(.monotonic);
    try std.testing.expect(export_count > 0);
}

test "BatchingLogRecordProcessor never exports concurrently and forceFlush waits for the batch in flight" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Holds its first batch inside `Export` until released, and records whether any `Export` call
    // overlapped another one or saw record strings that were freed or overwritten.
    const BlockingExporter = struct {
        calls: std.atomic.Value(usize) = .init(0),
        active: std.atomic.Value(usize) = .init(0),
        exported: std.atomic.Value(usize) = .init(0),
        first_started: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        overlapped: std.atomic.Value(bool) = .init(false),
        corrupted: std.atomic.Value(bool) = .init(false),

        pub fn exportLogs(ctx: *anyopaque, log_records: []logs.ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.active.fetchAdd(1, .acq_rel) != 0) self.overlapped.store(true, .release);
            defer _ = self.active.fetchSub(1, .acq_rel);

            if (self.calls.fetchAdd(1, .acq_rel) == 0) {
                self.first_started.store(true, .release);
                while (!self.release.load(.acquire)) std.Io.sleep(std.testing.io, .fromNanoseconds(1 * std.time.ns_per_ms), .awake) catch {};
            }
            for (log_records) |log_record| {
                const body = log_record.body.?.string;
                if (!std.mem.startsWith(u8, body, "first-") and
                    !std.mem.startsWith(u8, body, "flushed-") and
                    !std.mem.startsWith(u8, body, "second-"))
                {
                    self.corrupted.store(true, .release);
                }
            }
            _ = self.exported.fetchAdd(log_records.len, .acq_rel);
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

        fn waitFor(flag: *const std.atomic.Value(bool)) !void {
            var attempts: usize = 0;
            while (!flag.load(.acquire)) : (attempts += 1) {
                if (attempts == 5000) return error.Timeout;
                std.Io.sleep(std.testing.io, .fromNanoseconds(1 * std.time.ns_per_ms), .awake) catch {};
            }
        }
    };

    const Flusher = struct {
        fn run(p: LogRecordProcessor, done: *std.atomic.Value(bool)) void {
            p.forceFlush() catch {};
            done.store(true, .release);
        }
    };

    var mock_exporter: BlockingExporter = .{};
    var processor = try BatchingLogRecordProcessor.init(allocator, io, mock_exporter.asLogRecordExporter(), .{
        .max_export_batch_size = 10,
        .scheduled_delay_millis = 60_000,
    });
    defer {
        const log_processor = processor.asLogRecordProcessor();
        log_processor.shutdown() catch {};
        processor.deinit();
    }

    const log_processor = processor.asLogRecordProcessor();
    const ctx = context.Context.init();
    const scope = InstrumentationScope{ .name = "test-logger" };

    const emit = struct {
        fn run(p: LogRecordProcessor, c: context.Context, s: InstrumentationScope, prefix: []const u8, count: usize) !void {
            for (0..count) |i| {
                var body_buf: [64]u8 = undefined;
                const body = try std.fmt.bufPrint(&body_buf, "{s}-{d}-with-some-padding-to-fill-the-arena", .{ prefix, i });
                var log_record: logs.ReadWriteLogRecord = .{
                    .scope = s,
                    .observed_timestamp = 0,
                    .body = .{ .string = body },
                    .severity_number = 9,
                };
                defer log_record.deinit(std.testing.allocator);
                p.onEmit(&log_record, c);
            }
        }
    }.run;

    // A full batch wakes the background task, which pops it and blocks inside the exporter.
    try emit(log_processor, ctx, scope, "first", 10);
    try BlockingExporter.waitFor(&mock_exporter.first_started);
    try emit(log_processor, ctx, scope, "flushed", 3);
    try emit(log_processor, ctx, scope, "second", 9);

    // forceFlush from another thread must wait for the batch in flight instead of exporting
    // alongside it (and must not reset the arena that batch lives in).
    var flush_done: std.atomic.Value(bool) = .init(false);
    const flusher = try std.Thread.spawn(.{}, Flusher.run, .{ log_processor, &flush_done });
    defer {
        mock_exporter.release.store(true, .release);
        flusher.join();
    }
    std.Io.sleep(std.testing.io, .fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    try std.testing.expect(!flush_done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), mock_exporter.calls.load(.acquire));

    mock_exporter.release.store(true, .release);
    try BlockingExporter.waitFor(&flush_done);

    // Once forceFlush returns, everything queued before it has been exported.
    try std.testing.expectEqual(@as(usize, 22), mock_exporter.exported.load(.acquire));
    try std.testing.expect(!mock_exporter.overlapped.load(.acquire));
    try std.testing.expect(!mock_exporter.corrupted.load(.acquire));
}

test "BatchingLogRecordProcessor shutdown exports pending records" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const record_count = 6;

    // The exporter hits a cancelation point, so a canceled export task loses the batch.
    const CountingExporter = struct {
        io: std.Io,
        exported: usize = 0,

        pub fn exportLogs(ctx: *anyopaque, log_records: []logs.ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(1), .awake);
            self.exported += log_records.len;
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

    var counting = CountingExporter{ .io = io };
    var processor = try BatchingLogRecordProcessor.init(allocator, io, counting.asLogRecordExporter(), .{
        // Keep the background loop asleep so shutdown is what drives the export.
        .max_export_batch_size = record_count + 1,
        .scheduled_delay_millis = 60_000,
    });
    defer processor.deinit();

    const log_processor = processor.asLogRecordProcessor();
    for (0..record_count) |_| {
        var log_record: logs.ReadWriteLogRecord = .{
            .scope = InstrumentationScope{ .name = "test-logger" },
            .observed_timestamp = 0,
            .body = .{ .string = "pending log message" },
            .severity_number = 9,
        };
        defer log_record.deinit(allocator);
        log_processor.onEmit(&log_record, context.Context.init());
    }

    try log_processor.shutdown();
    try std.testing.expectEqual(@as(usize, record_count), counting.exported);
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
    var log_record: logs.ReadWriteLogRecord = .{
        .scope = scope,
        .observed_timestamp = 0,
        .body = .{ .string = "test message" },
        .severity_number = 9,
    };
    defer log_record.deinit(allocator);

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

test "LogRecordQueue wrap-around split" {
    const allocator = std.testing.allocator;

    var queue = try LogRecordQueue.init(allocator, 4);
    defer queue.deinit(allocator);

    const rec = struct {
        fn make(ts: u64) logs.ReadableLogRecord {
            return .{
                .timestamp = null,
                .observed_timestamp = ts,
                .trace_id = null,
                .span_id = null,
                .trace_flags = 0,
                .severity_number = null,
                .severity_text = null,
                .body = null,
                .attributes = &.{},
                .resource = null,
                .scope = .{ .name = "t" },
                .location = null,
                .event_name = null,
            };
        }
    }.make;

    // Push 2, pop 2 — head advances to 2
    try std.testing.expect(queue.push(rec(1)));
    try std.testing.expect(queue.push(rec(2)));
    var dest: [4]logs.ReadableLogRecord = undefined;
    _ = queue.popBatch(dest[0..2]);

    // Push 3 — occupies slots 2, 3, 0 (wraps around)
    try std.testing.expect(queue.push(rec(3)));
    try std.testing.expect(queue.push(rec(4)));
    try std.testing.expect(queue.push(rec(5)));

    // Pop 3: splitpoint = 4 - 2 = 2, count = 3 > splitpoint → second @memcpy fires
    const batch = queue.popBatch(dest[0..3]);
    try std.testing.expectEqual(@as(usize, 3), batch.len);
    try std.testing.expectEqual(@as(u64, 3), batch[0].observed_timestamp);
    try std.testing.expectEqual(@as(u64, 4), batch[1].observed_timestamp);
    try std.testing.expectEqual(@as(u64, 5), batch[2].observed_timestamp);
}

test "BatchingLogRecordProcessor memory stays bounded when the queue never drains" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const rounds = 200;
    const body: *const [1024]u8 = &@splat('x');

    // Queues a record on every export, so the queue is never empty once an export completes.
    const RefillingExporter = struct {
        processor: LogRecordProcessor = undefined,
        exported: usize = 0,

        pub fn exportLogs(ctx: *anyopaque, log_records: []logs.ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.exported += log_records.len;
            var log_record: logs.ReadWriteLogRecord = .{
                .scope = InstrumentationScope{ .name = "test-logger" },
                .observed_timestamp = 0,
                .body = .{ .string = body },
                .severity_number = 9,
            };
            defer log_record.deinit(std.testing.allocator);
            self.processor.onEmit(&log_record, context.Context.init());
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

    var refilling: RefillingExporter = .{};
    var processor = try BatchingLogRecordProcessor.init(allocator, io, refilling.asLogRecordExporter(), .{
        // Keep the background loop asleep so forceFlush is what drives the exports.
        .max_export_batch_size = 8,
        .scheduled_delay_millis = 60_000,
    });
    defer processor.deinit();
    refilling.processor = processor.asLogRecordProcessor();

    var log_record: logs.ReadWriteLogRecord = .{
        .scope = InstrumentationScope{ .name = "test-logger" },
        .observed_timestamp = 0,
        .body = .{ .string = body },
        .severity_number = 9,
    };
    defer log_record.deinit(allocator);
    refilling.processor.onEmit(&log_record, context.Context.init());

    for (0..rounds) |_| try refilling.processor.forceFlush();
    try std.testing.expectEqual(@as(usize, rounds), refilling.exported);

    // Without ever reaching an empty queue, every record would have been retained: rounds KiB.
    processor.mutex.lockUncancelable(io);
    var capacity: usize = 0;
    for (&processor.arenas) |*arena| capacity += arena.queryCapacity();
    processor.mutex.unlock(io);
    try std.testing.expect(capacity < rounds * body.len / 4);

    try refilling.processor.shutdown();
}

test "evenBatchSize spreads records evenly over the fewest batches" {
    try std.testing.expectEqual(@as(usize, 1), evenBatchSize(1, 512));
    try std.testing.expectEqual(@as(usize, 512), evenBatchSize(512, 512));
    try std.testing.expectEqual(@as(usize, 257), evenBatchSize(513, 512));
    try std.testing.expectEqual(@as(usize, 350), evenBatchSize(700, 512));
    try std.testing.expectEqual(@as(usize, 515), evenBatchSize(1030, 1024));
    try std.testing.expectEqual(@as(usize, 1024), evenBatchSize(2048, 1024));
    try std.testing.expectEqual(@as(usize, 1), evenBatchSize(5, 1));
}
