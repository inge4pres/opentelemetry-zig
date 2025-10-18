const std = @import("std");
const LogRecordExporter = @import("../../sdk/logs/log_record_exporter.zig").LogRecordExporter;
const SimpleLogRecordProcessor = @import("../../sdk/logs/log_record_processor.zig").SimpleLogRecordProcessor;
const LogRecordProcessor = @import("../../sdk/logs/log_record_processor.zig").LogRecordProcessor;
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const Context = @import("../context/context.zig").Context;

/// ReadWriteLogRecord is a mutable log record used during emission.
/// Processors can modify this record, and mutations are visible to subsequent processors.
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#logrecordprocessor
pub const ReadWriteLogRecord = struct {
    timestamp: ?u64,
    observed_timestamp: u64,
    trace_id: ?[16]u8,
    span_id: ?[8]u8,
    severity_number: ?u8,
    severity_text: ?[]const u8,
    body: ?[]const u8,
    attributes: std.ArrayListUnmanaged(Attribute),
    resource: ?[]const Attribute,
    scope: InstrumentationScope,

    const Self = @This();

    pub fn init(_: std.mem.Allocator, scope: InstrumentationScope) Self {
        return Self{
            .timestamp = null,
            .observed_timestamp = @intCast(std.time.nanoTimestamp()),
            .trace_id = null,
            .span_id = null,
            .severity_number = null,
            .severity_text = null,
            .body = null,
            .attributes = std.ArrayListUnmanaged(Attribute){},
            .resource = null,
            .scope = scope,
        };
    }

    pub fn setAttribute(self: *Self, allocator: std.mem.Allocator, attribute: Attribute) !void {
        try self.attributes.append(allocator, attribute);
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.attributes.deinit(allocator);
    }

    /// Convert to immutable ReadableLogRecord for export
    pub fn toReadable(self: *const Self, allocator: std.mem.Allocator) !ReadableLogRecord {
        const attrs = try allocator.alloc(Attribute, self.attributes.items.len);
        @memcpy(attrs, self.attributes.items);

        return ReadableLogRecord{
            .timestamp = self.timestamp,
            .observed_timestamp = self.observed_timestamp,
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .severity_number = self.severity_number,
            .severity_text = self.severity_text,
            .body = self.body,
            .attributes = attrs,
            .resource = self.resource,
            .scope = self.scope,
        };
    }
};

/// ReadableLogRecord is an immutable log record passed to exporters.
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#logrecordexporter
pub const ReadableLogRecord = struct {
    timestamp: ?u64,
    observed_timestamp: u64,
    trace_id: ?[16]u8,
    span_id: ?[8]u8,
    severity_number: ?u8,
    severity_text: ?[]const u8,
    body: ?[]const u8,
    attributes: []const Attribute,
    resource: ?[]const Attribute,
    scope: InstrumentationScope,

    const Self = @This();

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.attributes);
    }
};

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
    resource: ?[]const Attribute,
    is_shutdown: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, resource: ?[]const Attribute) !*Self {
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
            .resource = resource,
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
        var log_record = ReadWriteLogRecord.init(self.allocator, self.scope);
        defer log_record.deinit(self.allocator);

        log_record.severity_number = severity_number;
        log_record.severity_text = severity_text;
        log_record.body = body;
        log_record.resource = self.provider.resource;

        // Add attributes if provided
        if (attributes) |attrs| {
            for (attrs) |attr| {
                log_record.setAttribute(self.allocator, attr) catch |err| {
                    std.log.err("Failed to add attribute to log record: {}", .{err});
                };
            }
        }

        // Call processors in order
        const ctx = Context.init();
        self.provider.mutex.lock();
        defer self.provider.mutex.unlock();

        for (self.provider.processors.items) |processor| {
            processor.onEmit(&log_record, ctx);
        }
    }
};

test "LoggerProvider basic functionality" {
    const allocator = std.testing.allocator;

    var provider = try LoggerProvider.init(allocator, null);
    defer provider.deinit();

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);

    try std.testing.expectEqualDeep(scope, logger.scope);
}

test "LoggerProvider same logger for same scope" {
    const allocator = std.testing.allocator;

    var provider = try LoggerProvider.init(allocator, null);
    defer provider.deinit();

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger1 = try provider.getLogger(scope);
    const logger2 = try provider.getLogger(scope);

    try std.testing.expectEqual(logger1, logger2);
}

test "LoggerProvider with processor" {
    const allocator = std.testing.allocator;

    // Mock exporter
    const MockExporter = struct {
        export_count: usize = 0,

        pub fn exportLogs(ctx: *anyopaque, _: []ReadableLogRecord) anyerror!void {
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

    var provider = try LoggerProvider.init(allocator, null);
    defer provider.deinit();

    try provider.addLogRecordProcessor(log_processor);

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);

    // Emit a log
    logger.emit(9, "INFO", "test message", null);

    // Verify export was called
    try std.testing.expectEqual(@as(usize, 1), mock_exporter.export_count);
}

test "LoggerProvider with custom resource" {
    const allocator = std.testing.allocator;

    const service_name: []const u8 = "my-service";
    const service_version: []const u8 = "1.0.0";
    const deployment_env: []const u8 = "production";
    const resource_attrs = try Attributes.from(allocator, .{
        "service.name",    service_name,
        "service.version", service_version,
        "deployment.env",  deployment_env,
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);

    var provider = try LoggerProvider.init(allocator, resource_attrs);
    defer provider.deinit();

    try std.testing.expect(provider.resource != null);
    try std.testing.expectEqual(@as(usize, 3), provider.resource.?.len);
    try std.testing.expectEqualStrings("service.name", provider.resource.?[0].key);
    try std.testing.expectEqualStrings("my-service", provider.resource.?[0].value.string);
}

test "Log records inherit resource from provider" {
    const allocator = std.testing.allocator;

    const service_name: []const u8 = "test-service";
    const host_name: []const u8 = "test-host";
    const resource_attrs = try Attributes.from(allocator, .{
        "service.name", service_name,
        "host.name",    host_name,
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);

    // Mock exporter that captures the log record
    const MockExporter = struct {
        captured_resource: ?[]const Attribute = null,

        pub fn exportLogs(ctx: *anyopaque, records: []ReadableLogRecord) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (records.len > 0) {
                self.captured_resource = records[0].resource;
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

    var mock_exporter = MockExporter{};
    const exporter = mock_exporter.asLogRecordExporter();
    var processor = SimpleLogRecordProcessor.init(allocator, exporter);
    const log_processor = processor.asLogRecordProcessor();

    var provider = try LoggerProvider.init(allocator, resource_attrs);
    defer provider.deinit();

    try provider.addLogRecordProcessor(log_processor);

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);

    // Emit a log
    logger.emit(9, "INFO", "test message", null);

    // Verify resource was passed to the log record
    try std.testing.expect(mock_exporter.captured_resource != null);
    try std.testing.expectEqual(@as(usize, 2), mock_exporter.captured_resource.?.len);
    try std.testing.expectEqualStrings("service.name", mock_exporter.captured_resource.?[0].key);
    try std.testing.expectEqualStrings("test-service", mock_exporter.captured_resource.?[0].value.string);
}
