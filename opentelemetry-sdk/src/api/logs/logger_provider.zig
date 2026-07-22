const std = @import("std");
const clock = @import("clock");

// NOTE: API-surface mutex operations use lockUncancelable so that user-facing
// methods do not introduce cancellation points. This is safe with Io.Threaded
// (the default) but means user cancellations will be ignored if the SDK is
// used with Io.Evented. Switching to lock() would require propagating
// error{Canceled} through all public APIs.

const LogRecordExporter = @import("../../sdk/logs/log_record_exporter.zig").LogRecordExporter;
const SimpleLogRecordProcessor = @import("../../sdk/logs/log_record_processor.zig").SimpleLogRecordProcessor;
const BatchingLogRecordProcessor = @import("../../sdk/logs/log_record_processor.zig").BatchingLogRecordProcessor;
const LogRecordProcessor = @import("../../sdk/logs/log_record_processor.zig").LogRecordProcessor;
const Attribute = @import("../../attributes.zig").Attribute;
const AttributeValue = @import("../../attributes.zig").AttributeValue;
const Attributes = @import("../../attributes.zig").Attributes;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const context_api = @import("../context/context.zig");
const Context = context_api.Context;
const getCurrentContext = context_api.getCurrentContext;
const EnabledParameters = @import("enabled_parameters.zig").EnabledParameters;
const trace = @import("../trace.zig");

// Import configuration module
const Configuration = @import("../../sdk/config.zig").Configuration;
const resource_attributes = @import("../../sdk/resource.zig");

/// ReadWriteLogRecord is a mutable log record used during emission.
/// Processors can modify this record, and mutations are visible to subsequent processors.
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#logrecordprocessor
pub const ReadWriteLogRecord = struct {
    scope: InstrumentationScope,
    observed_timestamp: u64,
    timestamp: ?u64 = null,
    trace_id: ?[16]u8 = null,
    span_id: ?[8]u8 = null,
    trace_flags: ?u8 = null,
    severity_number: ?u8 = null,
    severity_text: ?[]const u8 = null,
    body: ?[]const u8 = null,
    attributes: std.ArrayListUnmanaged(Attribute) = .empty,
    resource: ?[]const Attribute = null,

    const Self = @This();

    pub fn setAttribute(self: *Self, allocator: std.mem.Allocator, attribute: Attribute) !void {
        try self.attributes.append(allocator, attribute);
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.attributes.deinit(allocator);
    }

    /// Borrow the log record as a ReadableLogRecord without copying any data.
    /// The returned record is only valid while this ReadWriteLogRecord is alive.
    /// Use this for synchronous export (SimpleLogRecordProcessor).
    pub fn asReadable(self: *const Self) ReadableLogRecord {
        return .{
            .timestamp = self.timestamp,
            .observed_timestamp = self.observed_timestamp,
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .trace_flags = self.trace_flags,
            .severity_number = self.severity_number,
            .severity_text = self.severity_text,
            .body = self.body,
            .attributes = self.attributes.items,
            .resource = self.resource,
            .scope = self.scope,
        };
    }

    /// Deep-copy all string data into the provided allocator and return an owned ReadableLogRecord.
    /// Primarily used with arena allocators (BatchingLogRecordProcessor).
    /// The caller is responsible for freeing the returned allocations.
    pub fn toReadable(self: *const Self, allocator: std.mem.Allocator) !ReadableLogRecord {
        const attrs = try allocator.alloc(Attribute, self.attributes.items.len);
        for (self.attributes.items, attrs) |source, *dest| {
            dest.* = .{
                .key = try allocator.dupe(u8, source.key),
                .value = switch (source.value) {
                    .string => |s| .{ .string = try allocator.dupe(u8, s) },
                    else => source.value,
                },
            };
        }
        return .{
            .timestamp = self.timestamp,
            .observed_timestamp = self.observed_timestamp,
            .trace_id = self.trace_id,
            .span_id = self.span_id,
            .trace_flags = self.trace_flags,
            .severity_number = self.severity_number,
            .severity_text = if (self.severity_text) |t| try allocator.dupe(u8, t) else null,
            .body = if (self.body) |b| try allocator.dupe(u8, b) else null,
            .attributes = attrs,
            .resource = self.resource,
            .scope = self.scope,
        };
    }
};

/// ReadableLogRecord is an immutable, non-owning view of a log record passed to exporters.
///
/// String fields may point into caller-owned memory (asReadable) or into a processor-owned
/// arena (toReadable). In either case, the record itself carries no ownership — the caller
/// is responsible for managing the underlying allocations.
///
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#logrecordexporter
pub const ReadableLogRecord = struct {
    timestamp: ?u64,
    observed_timestamp: u64,
    trace_id: ?[16]u8,
    span_id: ?[8]u8,
    trace_flags: ?u8,
    severity_number: ?u8,
    severity_text: ?[]const u8,
    body: ?[]const u8,
    attributes: []const Attribute,
    /// points into the LoggerProvider's resource
    resource: ?[]const Attribute,
    /// points into the Logger's scope
    scope: InstrumentationScope,
};

/// SDK LoggerProvider implementation
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#loggerprovider
pub const LoggerProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
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
    mutex: std.Io.Mutex,
    config: ?*const Configuration,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, resource: ?[]const Attribute) !*Self {
        const cfg = Configuration.get();
        const sdk_disabled = if (cfg) |c| c.sdk_disabled else false;

        // Only build resource attributes from config if SDK is enabled
        const merged_resource = if (!sdk_disabled) blk: {
            const cfg_resource_attributes: []Attribute = if (cfg) |c| try resource_attributes.buildFromConfig(allocator, c) else &.{};
            defer if (cfg_resource_attributes.len > 0) resource_attributes.freeResource(allocator, cfg_resource_attributes);
            break :blk try resource_attributes.mergeResources(
                allocator,
                if (resource) |r| r else &.{},
                cfg_resource_attributes,
            );
        } else null;

        const provider = try allocator.create(Self);
        provider.* = Self{
            .allocator = allocator,
            .io = io,
            .loggers = std.HashMapUnmanaged(
                InstrumentationScope,
                *Logger,
                InstrumentationScope.HashContext,
                std.hash_map.default_max_load_percentage,
            ){},
            .processors = .empty,
            .resource = merged_resource,
            .is_shutdown = std.atomic.Value(bool).init(false),
            .sdk_disabled = sdk_disabled,
            .mutex = std.Io.Mutex.init,
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.is_shutdown.load(.acquire)) {
            return error.LoggerProviderShutdown;
        }

        try self.processors.append(self.allocator, processor);
    }

    pub fn getLogger(self: *Self, scope: InstrumentationScope) !*Logger {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

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

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Shutdown all processors
        for (self.processors.items) |processor| {
            processor.shutdown() catch |err| {
                std.log.err("Failed to shutdown processor: {}", .{err});
            };
        }
    }

    pub fn forceFlush(self: *Self) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

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
        return try BatchingLogRecordProcessor.init(self.allocator, self.io, exporter, .{
            .max_queue_size = @intCast(lc.blrp_max_queue_size),
            .scheduled_delay_millis = lc.blrp_schedule_delay_ms,
            .export_timeout_millis = lc.blrp_export_timeout_ms,
            .max_export_batch_size = @intCast(lc.blrp_max_export_batch_size),
        });
    }
};

/// Severity level for a log record.
///
/// Simple variants map to the primary sub-level of each OTel severity group:
/// `trace`→1, `debug`→5, `info`→9, `warn`→13, `err`→17, `fatal`→21.
///
/// Use `.{ .severity = n }` when bridging from a system that exposes sub-level
/// granularity (e.g. INFO_2 = 10) or when passing an already-computed number.
/// Pass `null` to `emit` when no severity is set.
pub const Severity = union(enum) {
    trace,
    debug,
    info,
    warn,
    err,
    fatal,
    /// Raw OTel severity number (1–24).
    severity: u8,

    pub fn toNumber(self: Severity) u8 {
        return switch (self) {
            .trace => 1,
            .debug => 5,
            .info => 9,
            .warn => 13,
            .err => 17,
            .fatal => 21,
            .severity => |n| n,
        };
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

    pub const Options = struct {
        /// Timestamp of the original event (nanoseconds since Unix epoch).
        /// When bridging from another logging system, pass the original log timestamp.
        timestamp: ?u64 = null,

        /// Timestamp when the record was observed by the SDK (nanoseconds since Unix epoch).
        /// Defaults to the current time if not provided.
        observed_timestamp: ?u64 = null,

        /// Human-readable severity label (e.g. "WARN", "CRITICAL").
        /// Optional: backends can derive a standard label from `severity_number`.
        /// Useful when bridging from a logging system that has its own level names.
        severity_text: ?[]const u8 = null,

        /// Key-value pairs attached to this log record.
        attributes: ?[]const Attribute = null,

        /// Experimental: subject to change or removal in a future version.
        ///
        /// Span context to correlate this log record with an active trace.
        /// Pass `span.span_context` to enable log-trace correlation in the backend.
        span_context: ?trace.SpanContext = null,

        /// Propagation context forwarded to log processors on emit.
        /// If null, the active thread-local context is used.
        context: ?Context = null,
    };

    /// Emit a log record.
    pub fn emit(
        self: *Self,
        severity: ?Severity,
        body: []const u8,
        options: Options,
    ) void {
        if (self.provider.sdk_disabled or self.provider.is_shutdown.load(.acquire)) {
            return;
        }

        const context = options.context orelse getCurrentContext();

        // Spec: trace context fields MUST be populated from the resolved Context.
        // Explicit span_context (experimental) overrides context-derived values when provided.
        const span_context = options.span_context orelse trace.deserializeSpanContext(context);

        var log_record: ReadWriteLogRecord = .{
            .timestamp = options.timestamp,
            .observed_timestamp = options.observed_timestamp orelse @intCast(clock.nanoTimestamp()),
            .trace_id = if (span_context) |sc| sc.trace_id.toBinary() else null,
            .span_id = if (span_context) |sc| sc.span_id.toBinary() else null,
            .trace_flags = if (span_context) |sc| sc.trace_flags.value else null,
            .severity_number = if (severity) |s| s.toNumber() else null,
            .severity_text = options.severity_text,
            .body = body,
            .attributes = .empty,
            .resource = self.provider.resource,
            .scope = self.scope,
        };
        defer log_record.deinit(self.allocator);

        if (options.attributes) |attrs| {
            log_record.attributes.appendSlice(self.allocator, attrs) catch |err| {
                std.log.err("Failed to add attributes to log record: {}", .{err});
            };
        }
        self.provider.mutex.lockUncancelable(self.provider.io);
        defer self.provider.mutex.unlock(self.provider.io);

        for (self.provider.processors.items) |processor| {
            processor.onEmit(&log_record, context);
        }
    }

    /// Check if logging is enabled for the given parameters.
    /// Returns true if ANY processor would process a log record with these parameters.
    ///
    /// This method is useful for avoiding expensive operations when logging is disabled:
    /// ```zig
    /// if (logger.enabled(.{ .context = ctx, .severity = 9 })) {
    ///     const expensive_data = computeExpensiveDebugInfo();
    ///     logger.emit(.info, expensive_data, .{});
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
        self.provider.mutex.lockUncancelable(self.provider.io);
        defer self.provider.mutex.unlock(self.provider.io);

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
    const io = std.testing.io;

    var provider = try LoggerProvider.init(allocator, io, null);
    defer provider.deinit();

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);

    try std.testing.expectEqualDeep(scope, logger.scope);
}

test "LoggerProvider same logger for same scope" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var provider = try LoggerProvider.init(allocator, io, null);
    defer provider.deinit();

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger1 = try provider.getLogger(scope);
    const logger2 = try provider.getLogger(scope);

    try std.testing.expectEqual(logger1, logger2);
}

test "LoggerProvider with processor" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

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
    var processor = SimpleLogRecordProcessor.init(io, exporter);
    const log_processor = processor.asLogRecordProcessor();

    var provider = try LoggerProvider.init(allocator, io, null);
    defer provider.deinit();

    try provider.addLogRecordProcessor(log_processor);

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);

    // Emit a log
    logger.emit(.info, "test message", .{});

    // Verify export was called
    try std.testing.expectEqual(@as(usize, 1), mock_exporter.export_count);
}

test "LoggerProvider with custom resource" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const service_name: []const u8 = "my-service";
    const service_version: []const u8 = "1.0.0";
    const deployment_env: []const u8 = "production";
    const resource_attrs = try Attributes.from(allocator, .{
        "service.name",    service_name,
        "service.version", service_version,
        "deployment.env",  deployment_env,
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);

    var provider = try LoggerProvider.init(allocator, io, resource_attrs);
    defer provider.deinit();

    try std.testing.expect(provider.resource != null);
    try std.testing.expectEqual(@as(usize, 3), provider.resource.?.len);
    try std.testing.expectEqualStrings("service.name", provider.resource.?[0].key);
    try std.testing.expectEqualStrings("my-service", provider.resource.?[0].value.string);
}

test "Logger log records inherit resource from provider" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

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
    var processor = SimpleLogRecordProcessor.init(io, exporter);
    const log_processor = processor.asLogRecordProcessor();

    var provider = try LoggerProvider.init(allocator, io, resource_attrs);
    defer provider.deinit();

    try provider.addLogRecordProcessor(log_processor);

    const scope = InstrumentationScope{ .name = "test-logger" };
    const logger = try provider.getLogger(scope);

    // Emit a log
    logger.emit(.info, "test message", .{});

    // Verify resource was passed to the log record
    try std.testing.expect(mock_exporter.captured_resource != null);
    try std.testing.expectEqual(@as(usize, 2), mock_exporter.captured_resource.?.len);
    try std.testing.expectEqualStrings("service.name", mock_exporter.captured_resource.?[0].key);
    try std.testing.expectEqualStrings("test-service", mock_exporter.captured_resource.?[0].value.string);
}

test "Logger.enabled() returns true with active processors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

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
    var processor = SimpleLogRecordProcessor.init(io, exporter);
    const log_processor = processor.asLogRecordProcessor();

    var provider = try LoggerProvider.init(allocator, io, null);
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
    const io = std.testing.io;

    var provider = try LoggerProvider.init(allocator, io, null);
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
    const io = std.testing.io;

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
    var processor = SimpleLogRecordProcessor.init(io, exporter);
    const log_processor = processor.asLogRecordProcessor();

    var provider = try LoggerProvider.init(allocator, io, null);
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
    const io = std.testing.io;

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

    var provider = try LoggerProvider.init(allocator, io, null);
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
    const io = std.testing.io;

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

    var provider = try LoggerProvider.init(allocator, io, null);
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
    const io = std.testing.io;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const cfg = try Configuration.init(allocator, &env_map);
    defer cfg.deinit();
    Configuration.set(cfg);

    var provider = try LoggerProvider.init(allocator, io, null);
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
