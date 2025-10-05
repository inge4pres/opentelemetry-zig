const std = @import("std");
const logs_api = @import("../../api/logs/logger_provider.zig");
const LogRecordProcessor = @import("log_record_processor.zig").LogRecordProcessor;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const context = @import("../../api/context.zig");

/// SDK LoggerProvider implementation
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#loggerprovider
pub const LoggerProvider = struct {
    allocator: std.mem.Allocator,
    loggers: std.HashMapUnmanaged(
        InstrumentationScope,
        *Logger,
        InstrumentationScope.HashContext,
        std.hash_map.default_max_load_percentage,
    ),
    processors: std.ArrayListUnmanaged(LogRecordProcessor),
    resource: ?*const anyopaque,
    is_shutdown: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const provider = try allocator.create(Self);
        provider.* = Self{
            .allocator = allocator,
            .loggers = std.HashMapUnmanaged(
                InstrumentationScope,
                *Logger,
                InstrumentationScope.HashContext,
                std.hash_map.default_max_load_percentage,
            ){},
            .processors = std.ArrayListUnmanaged(LogRecordProcessor){},
            .resource = null,
            .is_shutdown = std.atomic.Value(bool).init(false),
            .mutex = std.Thread.Mutex{},
        };
        return provider;
    }

    pub fn deinit(self: *Self) void {
        // Clean up loggers
        var logger_iter = self.loggers.valueIterator();
        while (logger_iter.next()) |logger| {
            logger.*.deinit();
        }
        self.loggers.deinit(self.allocator);

        self.processors.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addLogRecordProcessor(self: *Self, processor: LogRecordProcessor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown.load(.acquire)) {
            return error.LoggerProviderShutdown;
        }

        try self.processors.append(self.allocator, processor);
    }

    pub fn getLogger(self: *Self, scope: InstrumentationScope) !*Logger {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown.load(.acquire)) {
            return error.LoggerProviderShutdown;
        }

        if (self.loggers.get(scope)) |logger| {
            return logger;
        }

        const logger = try Logger.init(self.allocator, self, scope);
        try self.loggers.put(self.allocator, scope, logger);
        return logger;
    }

    pub fn shutdown(self: *Self) !void {
        if (self.is_shutdown.swap(true, .acq_rel)) {
            return; // Already shutdown
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Shutdown all processors
        for (self.processors.items) |processor| {
            processor.shutdown() catch |err| {
                std.log.err("Failed to shutdown processor: {}", .{err});
            };
        }
    }

    pub fn forceFlush(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown.load(.acquire)) {
            return error.LoggerProviderShutdown;
        }

        // Force flush all processors
        for (self.processors.items) |processor| {
            try processor.forceFlush();
        }
    }
};

/// Logger implementation
pub const Logger = struct {
    allocator: std.mem.Allocator,
    provider: *LoggerProvider,
    scope: InstrumentationScope,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, provider: *LoggerProvider, scope: InstrumentationScope) !*Self {
        const logger = try allocator.create(Self);
        logger.* = Self{
            .allocator = allocator,
            .provider = provider,
            .scope = scope,
        };
        return logger;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Emit a log record
    pub fn emit(
        self: *Self,
        severity_number: ?u8,
        severity_text: ?[]const u8,
        body: ?[]const u8,
        attributes: ?[]const @import("../../attributes.zig").Attribute,
    ) void {
        if (self.provider.is_shutdown.load(.acquire)) {
            return;
        }

        // Create ReadWriteLogRecord
        var log_record = logs_api.ReadWriteLogRecord.init(self.allocator, self.scope);
        defer log_record.deinit(self.allocator);

        log_record.severity_number = severity_number;
        log_record.severity_text = severity_text;
        log_record.body = body;

        // Add attributes if provided
        if (attributes) |attrs| {
            for (attrs) |attr| {
                log_record.setAttribute(self.allocator, attr) catch |err| {
                    std.log.err("Failed to add attribute to log record: {}", .{err});
                };
            }
        }

        // Call processors in order
        const ctx = context.Context.init();
        self.provider.mutex.lock();
        defer self.provider.mutex.unlock();

        for (self.provider.processors.items) |processor| {
            processor.onEmit(&log_record, ctx);
        }
    }
};

test "LoggerProvider basic functionality" {
    const allocator = std.testing.allocator;

    var provider = try LoggerProvider.init(allocator);
    defer provider.deinit();

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);

    try std.testing.expectEqualDeep(scope, logger.scope);
}

test "LoggerProvider same logger for same scope" {
    const allocator = std.testing.allocator;

    var provider = try LoggerProvider.init(allocator);
    defer provider.deinit();

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger1 = try provider.getLogger(scope);
    const logger2 = try provider.getLogger(scope);

    try std.testing.expectEqual(logger1, logger2);
}

test "LoggerProvider with processor" {
    const allocator = std.testing.allocator;
    const LogRecordExporter = @import("log_record_exporter.zig").LogRecordExporter;
    const SimpleLogRecordProcessor = @import("log_record_processor.zig").SimpleLogRecordProcessor;

    // Mock exporter
    const MockExporter = struct {
        export_count: usize = 0,

        pub fn exportLogs(ctx: *anyopaque, _: []logs_api.ReadableLogRecord) anyerror!void {
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

    var provider = try LoggerProvider.init(allocator);
    defer provider.deinit();

    try provider.addLogRecordProcessor(log_processor);

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);

    // Emit a log
    logger.emit(9, "INFO", "test message", null);

    // Verify export was called
    try std.testing.expectEqual(@as(usize, 1), mock_exporter.export_count);
}
