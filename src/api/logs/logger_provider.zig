const std = @import("std");
const LogRecordExporter = @import("../../sdk/logs/log_record_exporter.zig").LogRecordExporter;
const SimpleLogRecordProcessor = @import("../../sdk/logs/log_record_processor.zig").SimpleLogRecordProcessor;
const BatchingLogRecordProcessor = @import("../../sdk/logs/log_record_processor.zig").BatchingLogRecordProcessor;
const LogRecordProcessor = @import("../../sdk/logs/log_record_processor.zig").LogRecordProcessor;
const Attribute = @import("../../attributes.zig").Attribute;
const AttributeValue = @import("../../attributes.zig").AttributeValue;
const Attributes = @import("../../attributes.zig").Attributes;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const Context = @import("../context/context.zig").Context;
const EnabledParameters = @import("enabled_parameters.zig").EnabledParameters;

// Import configuration module
const Configuration = @import("../../sdk/config.zig").Configuration;
const resource_attributes = @import("../../sdk/resource.zig");

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

    pub fn init(scope: InstrumentationScope) Self {
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
    sdk_disabled: bool,
    mutex: std.Thread.Mutex,
    config: ?*const Configuration,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, resource: ?[]const Attribute) !*Self {
        const cfg = Configuration.get();
        const sdk_disabled = if (cfg) |c| c.sdk_disabled else false;
        const cfg_resource_attributes: []Attribute = if (cfg) |c| try resource_attributes.buildFromConfig(allocator, c) else &.{};

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
            .resource = if (sdk_disabled) null else try resource_attributes.mergeResources(
                allocator,
                if (resource) |r| r else &.{},
                cfg_resource_attributes,
            ),
            .is_shutdown = std.atomic.Value(bool).init(false),
            .sdk_disabled = sdk_disabled,
            .mutex = std.Thread.Mutex{},
            .config = cfg,
        };

        if (sdk_disabled) {
            std.log.info("LoggerProvider: SDK disabled via OTEL_SDK_DISABLED", .{});
        }

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

        if (self.resource) |r| resource_attributes.freeResource(self.allocator, r);

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

    /// Create a BatchingLogRecordProcessor with configuration from the global config
    pub fn createBatchProcessorFromConfig(
        self: *Self,
        exporter: LogRecordExporter,
    ) !*BatchingLogRecordProcessor {
        const lc = self.config.?.logs_config;
        return try BatchingLogRecordProcessor.init(self.allocator, exporter, .{
            .max_queue_size = @intCast(lc.blrp_max_queue_size),
            .scheduled_delay_millis = lc.blrp_schedule_delay_ms,
            .export_timeout_millis = lc.blrp_export_timeout_ms,
            .max_export_batch_size = @intCast(lc.blrp_max_export_batch_size),
        });
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
        attributes: ?[]const Attribute,
    ) void {
        if (self.provider.sdk_disabled or self.provider.is_shutdown.load(.acquire)) {
            return;
        }

        // Create ReadWriteLogRecord
        var log_record = ReadWriteLogRecord.init(self.scope);
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

    /// Check if logging is enabled for the given parameters.
    /// Returns true if ANY processor would process a log record with these parameters.
    ///
    /// This method is useful for avoiding expensive operations when logging is disabled:
    /// ```zig
    /// if (logger.enabled(.{ .context = ctx, .severity = 9 })) {
    ///     const expensive_data = computeExpensiveDebugInfo();
    ///     logger.emit(9, "INFO", expensive_data, null);
    /// }
    /// ```
    ///
    /// See: https://opentelemetry.io/docs/specs/otel/logs/bridge-api/#enabled
    pub fn enabled(self: *Self, params: struct {
        context: Context,
        severity: ?u8 = null,
        event_name: ?[]const u8 = null,
    }) bool {
        // Early return if SDK is disabled or provider is shutdown
        if (self.provider.sdk_disabled or self.provider.is_shutdown.load(.acquire)) {
            return false;
        }

        // Create full parameters with this logger's scope
        const full_params = EnabledParameters{
            .scope = self.scope,
            .severity = params.severity,
            .event_name = params.event_name,
            .context = params.context,
        };

        // Check with processors - if ANY processor would process it, return true
        self.provider.mutex.lock();
        defer self.provider.mutex.unlock();

        for (self.provider.processors.items) |processor| {
            if (processor.enabled(full_params)) {
                return true;
            }
        }

        // If no processors, return false
        // Per Go implementation: return false when no processor would handle it
        return false;
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

test "Logger log records inherit resource from provider" {
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

test "Logger.enabled() returns true with active processors" {
    const allocator = std.testing.allocator;

    // Mock exporter
    const MockExporter = struct {
        pub fn exportLogs(_: *anyopaque, _: []ReadableLogRecord) anyerror!void {}
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

    const ctx = Context.init();

    // Should be enabled with processor
    try std.testing.expect(logger.enabled(.{ .context = ctx }));
    try std.testing.expect(logger.enabled(.{ .context = ctx, .severity = 9 }));
    try std.testing.expect(logger.enabled(.{ .context = ctx, .severity = 17 }));
}

test "Logger.enabled() returns false when no processors" {
    const allocator = std.testing.allocator;

    var provider = try LoggerProvider.init(allocator, null);
    defer provider.deinit();

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);

    const ctx = Context.init();

    // Should be disabled with no processors
    try std.testing.expect(!logger.enabled(.{ .context = ctx }));
    try std.testing.expect(!logger.enabled(.{ .context = ctx, .severity = 9 }));
}

test "Logger.enabled() returns false after shutdown" {
    const allocator = std.testing.allocator;

    // Mock exporter
    const MockExporter = struct {
        pub fn exportLogs(_: *anyopaque, _: []ReadableLogRecord) anyerror!void {}
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

    const ctx = Context.init();

    // Should be enabled before shutdown
    try std.testing.expect(logger.enabled(.{ .context = ctx }));

    // Shutdown
    try provider.shutdown();

    // Should be disabled after shutdown
    try std.testing.expect(!logger.enabled(.{ .context = ctx }));
}

test "Logger.enabled() with multiple processors (OR logic)" {
    const allocator = std.testing.allocator;

    // Create a custom processor that always returns false
    const AlwaysDisabledProcessor = struct {
        fn onEmit(_: *anyopaque, _: *ReadWriteLogRecord, _: Context) void {}
        fn shutdown(_: *anyopaque) anyerror!void {}
        fn forceFlush(_: *anyopaque) anyerror!void {}
        fn isEnabled(_: *anyopaque, _: EnabledParameters) bool {
            return false;
        }

        pub fn asLogRecordProcessor(self: *@This()) LogRecordProcessor {
            return LogRecordProcessor{
                .ptr = self,
                .vtable = &.{
                    .onEmitFn = onEmit,
                    .shutdownFn = shutdown,
                    .forceFlushFn = forceFlush,
                    .enabledFn = isEnabled,
                },
            };
        }
    };

    // Create a custom processor that always returns true
    const AlwaysEnabledProcessor = struct {
        fn onEmit(_: *anyopaque, _: *ReadWriteLogRecord, _: Context) void {}
        fn shutdown(_: *anyopaque) anyerror!void {}
        fn forceFlush(_: *anyopaque) anyerror!void {}
        fn isEnabled(_: *anyopaque, _: EnabledParameters) bool {
            return true;
        }

        pub fn asLogRecordProcessor(self: *@This()) LogRecordProcessor {
            return LogRecordProcessor{
                .ptr = self,
                .vtable = &.{
                    .onEmitFn = onEmit,
                    .shutdownFn = shutdown,
                    .forceFlushFn = forceFlush,
                    .enabledFn = isEnabled,
                },
            };
        }
    };

    var provider = try LoggerProvider.init(allocator, null);
    defer provider.deinit();

    var disabled_proc = AlwaysDisabledProcessor{};
    var enabled_proc = AlwaysEnabledProcessor{};

    // Add disabled processor first
    try provider.addLogRecordProcessor(disabled_proc.asLogRecordProcessor());

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);
    const ctx = Context.init();

    // Should be false with only disabled processor
    try std.testing.expect(!logger.enabled(.{ .context = ctx }));

    // Add enabled processor
    try provider.addLogRecordProcessor(enabled_proc.asLogRecordProcessor());

    // Should be true with OR logic (at least one enabled)
    try std.testing.expect(logger.enabled(.{ .context = ctx }));
}

test "Logger.enabled() with severity parameter" {
    const allocator = std.testing.allocator;

    // Create a severity-filtering processor
    const SeverityFilterProcessor = struct {
        min_severity: u8,

        fn onEmit(_: *anyopaque, _: *ReadWriteLogRecord, _: Context) void {}
        fn shutdown(_: *anyopaque) anyerror!void {}
        fn forceFlush(_: *anyopaque) anyerror!void {}
        fn isEnabled(ctx: *anyopaque, params: EnabledParameters) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (params.severity) |sev| {
                return sev >= self.min_severity;
            }
            return true; // Default to true when severity not specified
        }

        pub fn asLogRecordProcessor(self: *@This()) LogRecordProcessor {
            return LogRecordProcessor{
                .ptr = self,
                .vtable = &.{
                    .onEmitFn = onEmit,
                    .shutdownFn = shutdown,
                    .forceFlushFn = forceFlush,
                    .enabledFn = isEnabled,
                },
            };
        }
    };

    var provider = try LoggerProvider.init(allocator, null);
    defer provider.deinit();

    var filter_proc = SeverityFilterProcessor{ .min_severity = 9 }; // INFO level
    try provider.addLogRecordProcessor(filter_proc.asLogRecordProcessor());

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);
    const ctx = Context.init();

    // DEBUG (5) should be disabled
    try std.testing.expect(!logger.enabled(.{ .context = ctx, .severity = 5 }));

    // INFO (9) should be enabled
    try std.testing.expect(logger.enabled(.{ .context = ctx, .severity = 9 }));

    // ERROR (17) should be enabled
    try std.testing.expect(logger.enabled(.{ .context = ctx, .severity = 17 }));

    // No severity specified should be enabled (defaults to true)
    try std.testing.expect(logger.enabled(.{ .context = ctx }));
}

test "LoggerProvider with config from environment" {
    const allocator = std.testing.allocator;

    const cfg = try Configuration.initFromEnv(allocator);
    defer cfg.deinit();
    Configuration.set(cfg);

    var provider = try LoggerProvider.init(allocator, null);
    defer provider.deinit();

    // Verify that we can create a batch processor using config
    const MockExporter = struct {
        pub fn exportLogs(_: *anyopaque, _: []ReadableLogRecord) anyerror!void {}
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

    var batch_processor = try provider.createBatchProcessorFromConfig(exporter);
    defer {
        const processor = batch_processor.asLogRecordProcessor();
        processor.shutdown() catch {};
        batch_processor.deinit();
    }

    // Verify processor was created with config values
    const lc = provider.config.?.logs_config;
    try std.testing.expectEqual(@as(usize, @intCast(lc.blrp_max_queue_size)), batch_processor.max_queue_size);
    try std.testing.expectEqual(lc.blrp_schedule_delay_ms, batch_processor.scheduled_delay_millis);
    try std.testing.expectEqual(lc.blrp_export_timeout_ms, batch_processor.export_timeout_millis);
    try std.testing.expectEqual(@as(usize, @intCast(lc.blrp_max_export_batch_size)), batch_processor.max_export_batch_size);
}
