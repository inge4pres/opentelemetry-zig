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