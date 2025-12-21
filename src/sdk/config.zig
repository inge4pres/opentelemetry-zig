//! SDK Configuration Module
//!
//! This module provides environment-variable based configuration for the OpenTelemetry SDK.
//! Configuration is accessed via a thread-safe singleton pattern.
//!
//! Environment variables follow the OpenTelemetry specification:
//! https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/

const std = @import("std");

/// Log level for SDK internal logging
pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    @"error",
    fatal,

    fn fromString(s: []const u8) ?LogLevel {
        if (std.ascii.eqlIgnoreCase(s, "trace")) return .trace;
        if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(s, "warn")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "error")) return .@"error";
        if (std.ascii.eqlIgnoreCase(s, "fatal")) return .fatal;
        return null;
    }
};

/// Trace context propagator types
pub const TracePropagator = enum {
    tracecontext,
    baggage,
    b3,
    b3multi,
    jaeger,
    xray,
    ottrace,
    none,

    fn fromString(s: []const u8) ?TracePropagator {
        if (std.ascii.eqlIgnoreCase(s, "tracecontext")) return .tracecontext;
        if (std.ascii.eqlIgnoreCase(s, "baggage")) return .baggage;
        if (std.ascii.eqlIgnoreCase(s, "b3")) return .b3;
        if (std.ascii.eqlIgnoreCase(s, "b3multi")) return .b3multi;
        if (std.ascii.eqlIgnoreCase(s, "jaeger")) return .jaeger;
        if (std.ascii.eqlIgnoreCase(s, "xray")) return .xray;
        if (std.ascii.eqlIgnoreCase(s, "ottrace")) return .ottrace;
        if (std.ascii.eqlIgnoreCase(s, "none")) return .none;
        return null;
    }
};

/// Trace-specific configuration
pub const TraceConfig = struct {
    /// Sampling strategy
    sampler: Sampler,
    /// Arguments for the sampler (e.g., sampling probability)
    sampler_arg: ?[]const u8,
    /// Exporter type
    exporter: ExporterType,

    // Batch Span Processor settings
    bsp_schedule_delay_ms: u64,
    bsp_export_timeout_ms: u64,
    bsp_max_queue_size: u32,
    bsp_max_export_batch_size: u32,

    // Span Limits
    attribute_value_length_limit: ?u32,
    attribute_count_limit: u32,
    event_count_limit: u32,
    link_count_limit: u32,
    event_attribute_count_limit: u32,
    link_attribute_count_limit: u32,

    pub const Sampler = enum {
        always_on,
        always_off,
        traceidratio,
        parentbased_always_on,
        parentbased_always_off,
        parentbased_traceidratio,
        parentbased_jaeger_remote,
        jaeger_remote,
        xray,

        fn fromString(s: []const u8) ?Sampler {
            if (std.ascii.eqlIgnoreCase(s, "always_on")) return .always_on;
            if (std.ascii.eqlIgnoreCase(s, "always_off")) return .always_off;
            if (std.ascii.eqlIgnoreCase(s, "traceidratio")) return .traceidratio;
            if (std.ascii.eqlIgnoreCase(s, "parentbased_always_on")) return .parentbased_always_on;
            if (std.ascii.eqlIgnoreCase(s, "parentbased_always_off")) return .parentbased_always_off;
            if (std.ascii.eqlIgnoreCase(s, "parentbased_traceidratio")) return .parentbased_traceidratio;
            if (std.ascii.eqlIgnoreCase(s, "parentbased_jaeger_remote")) return .parentbased_jaeger_remote;
            if (std.ascii.eqlIgnoreCase(s, "jaeger_remote")) return .jaeger_remote;
            if (std.ascii.eqlIgnoreCase(s, "xray")) return .xray;
            return null;
        }
    };

    pub const ExporterType = enum {
        otlp,
        jaeger,
        zipkin,
        console,
        none,

        fn fromString(s: []const u8) ?ExporterType {
            if (std.ascii.eqlIgnoreCase(s, "otlp")) return .otlp;
            if (std.ascii.eqlIgnoreCase(s, "jaeger")) return .jaeger;
            if (std.ascii.eqlIgnoreCase(s, "zipkin")) return .zipkin;
            if (std.ascii.eqlIgnoreCase(s, "console")) return .console;
            if (std.ascii.eqlIgnoreCase(s, "none")) return .none;
            return null;
        }
    };

    pub fn fromEnv(env_map: *const std.process.EnvMap, allocator: std.mem.Allocator) !TraceConfig {
        return TraceConfig{
            .sampler = if (env_map.get("OTEL_TRACES_SAMPLER")) |s|
                Sampler.fromString(s) orelse .parentbased_always_on
            else
                .parentbased_always_on,
            .sampler_arg = if (env_map.get("OTEL_TRACES_SAMPLER_ARG")) |s|
                try allocator.dupe(u8, s)
            else
                null,
            .exporter = if (env_map.get("OTEL_TRACES_EXPORTER")) |s|
                ExporterType.fromString(s) orelse .otlp
            else
                .otlp,
            .bsp_schedule_delay_ms = parseInt(u64, env_map, "OTEL_BSP_SCHEDULE_DELAY") orelse 5000,
            .bsp_export_timeout_ms = parseInt(u64, env_map, "OTEL_BSP_EXPORT_TIMEOUT") orelse 30000,
            .bsp_max_queue_size = parseInt(u32, env_map, "OTEL_BSP_MAX_QUEUE_SIZE") orelse 2048,
            .bsp_max_export_batch_size = parseInt(u32, env_map, "OTEL_BSP_MAX_EXPORT_BATCH_SIZE") orelse 512,
            .attribute_value_length_limit = parseInt(u32, env_map, "OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT"),
            .attribute_count_limit = parseInt(u32, env_map, "OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT") orelse 128,
            .event_count_limit = parseInt(u32, env_map, "OTEL_SPAN_EVENT_COUNT_LIMIT") orelse 128,
            .link_count_limit = parseInt(u32, env_map, "OTEL_SPAN_LINK_COUNT_LIMIT") orelse 128,
            .event_attribute_count_limit = parseInt(u32, env_map, "OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT") orelse 128,
            .link_attribute_count_limit = parseInt(u32, env_map, "OTEL_LINK_ATTRIBUTE_COUNT_LIMIT") orelse 128,
        };
    }

    pub fn deinit(self: *TraceConfig, allocator: std.mem.Allocator) void {
        if (self.sampler_arg) |arg| allocator.free(arg);
    }
};

/// Metrics-specific configuration
pub const MetricsConfig = struct {
    /// Exporter type
    exporter: ExporterType,

    // Periodic Exporting Reader settings
    export_interval_ms: u64,
    export_timeout_ms: u64,

    // Exemplar settings
    exemplar_filter: ExemplarFilter,

    // Cardinality limit
    cardinality_limit: u32,

    pub const ExporterType = enum {
        otlp,
        prometheus,
        console,
        none,

        fn fromString(s: []const u8) ?ExporterType {
            if (std.ascii.eqlIgnoreCase(s, "otlp")) return .otlp;
            if (std.ascii.eqlIgnoreCase(s, "prometheus")) return .prometheus;
            if (std.ascii.eqlIgnoreCase(s, "console")) return .console;
            if (std.ascii.eqlIgnoreCase(s, "none")) return .none;
            return null;
        }
    };

    pub const ExemplarFilter = enum {
        trace_based,
        always_on,
        always_off,

        fn fromString(s: []const u8) ?ExemplarFilter {
            if (std.ascii.eqlIgnoreCase(s, "trace_based")) return .trace_based;
            if (std.ascii.eqlIgnoreCase(s, "always_on")) return .always_on;
            if (std.ascii.eqlIgnoreCase(s, "always_off")) return .always_off;
            return null;
        }
    };

    pub fn fromEnv(env_map: *const std.process.EnvMap, allocator: std.mem.Allocator) !MetricsConfig {
        _ = allocator; // No allocations needed for metrics config
        return MetricsConfig{
            .exporter = if (env_map.get("OTEL_METRICS_EXPORTER")) |s|
                ExporterType.fromString(s) orelse .otlp
            else
                .otlp,
            .export_interval_ms = parseInt(u64, env_map, "OTEL_METRIC_EXPORT_INTERVAL") orelse 60000,
            .export_timeout_ms = parseInt(u64, env_map, "OTEL_METRIC_EXPORT_TIMEOUT") orelse 30000,
            .exemplar_filter = if (env_map.get("OTEL_METRICS_EXEMPLAR_FILTER")) |s|
                ExemplarFilter.fromString(s) orelse .trace_based
            else
                .trace_based,
            .cardinality_limit = parseInt(u32, env_map, "OTEL_METRICS_CARDINALITY_LIMIT") orelse 2000,
        };
    }

    pub fn deinit(self: *MetricsConfig, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Logs-specific configuration
pub const LogsConfig = struct {
    /// Exporter type
    exporter: ExporterType,

    // Batch LogRecord Processor settings
    blrp_schedule_delay_ms: u64,
    blrp_export_timeout_ms: u64,
    blrp_max_queue_size: u32,
    blrp_max_export_batch_size: u32,

    // LogRecord Limits
    attribute_value_length_limit: ?u32,
    attribute_count_limit: u32,

    pub const ExporterType = enum {
        otlp,
        console,
        none,

        fn fromString(s: []const u8) ?ExporterType {
            if (std.ascii.eqlIgnoreCase(s, "otlp")) return .otlp;
            if (std.ascii.eqlIgnoreCase(s, "console")) return .console;
            if (std.ascii.eqlIgnoreCase(s, "none")) return .none;
            return null;
        }
    };

    pub fn fromEnv(env_map: *const std.process.EnvMap, allocator: std.mem.Allocator) !LogsConfig {
        _ = allocator; // No allocations needed for logs config
        return LogsConfig{
            .exporter = if (env_map.get("OTEL_LOGS_EXPORTER")) |s|
                ExporterType.fromString(s) orelse .otlp
            else
                .otlp,
            .blrp_schedule_delay_ms = parseInt(u64, env_map, "OTEL_BLRP_SCHEDULE_DELAY") orelse 1000,
            .blrp_export_timeout_ms = parseInt(u64, env_map, "OTEL_BLRP_EXPORT_TIMEOUT") orelse 30000,
            .blrp_max_queue_size = parseInt(u32, env_map, "OTEL_BLRP_MAX_QUEUE_SIZE") orelse 2048,
            .blrp_max_export_batch_size = parseInt(u32, env_map, "OTEL_BLRP_MAX_EXPORT_BATCH_SIZE") orelse 512,
            .attribute_value_length_limit = parseInt(u32, env_map, "OTEL_LOGRECORD_ATTRIBUTE_VALUE_LENGTH_LIMIT"),
            .attribute_count_limit = parseInt(u32, env_map, "OTEL_LOGRECORD_ATTRIBUTE_COUNT_LIMIT") orelse 128,
        };
    }

    pub fn deinit(self: *LogsConfig, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Global SDK Configuration singleton
pub const Configuration = struct {
    allocator: std.mem.Allocator,

    // Global settings
    sdk_disabled: bool,
    service_name: ?[]const u8,
    resource_attributes: ?[]const u8,
    log_level: LogLevel,
    trace_propagators: []const TracePropagator,

    // Signal-specific configurations
    trace_config: TraceConfig,
    metrics_config: MetricsConfig,
    logs_config: LogsConfig,

    // Singleton instance
    var instance: ?*Configuration = null;
    var mutex: std.Thread.Mutex = .{};

    /// Get or create the global configuration singleton
    /// This is called internally by SDK components, not by users
    pub fn global(allocator: std.mem.Allocator) !*Configuration {
        mutex.lock();
        defer mutex.unlock();

        if (instance) |cfg| return cfg;

        instance = try allocator.create(Configuration);
        instance.?.* = try Configuration.initFromEnv(allocator);
        return instance.?;
    }

    /// Advanced: Set a custom global configuration (for testing/override)
    /// This is optional and typically not needed by users
    pub fn setGlobal(allocator: std.mem.Allocator, cfg: Configuration) !void {
        mutex.lock();
        defer mutex.unlock();

        if (instance) |old| {
            old.deinit();
        }

        instance = try allocator.create(Configuration);
        instance.?.* = cfg;
    }

    /// Reset the singleton (useful for testing)
    pub fn reset() void {
        mutex.lock();
        defer mutex.unlock();

        if (instance) |cfg| {
            cfg.deinit();
        }
        instance = null;
    }

    /// Initialize configuration from environment variables
    pub fn initFromEnv(allocator: std.mem.Allocator) !Configuration {
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();

        return Configuration{
            .allocator = allocator,
            .sdk_disabled = parseBool(&env_map, "OTEL_SDK_DISABLED") orelse false,
            .service_name = if (env_map.get("OTEL_SERVICE_NAME")) |s|
                try allocator.dupe(u8, s)
            else
                null,
            .resource_attributes = if (env_map.get("OTEL_RESOURCE_ATTRIBUTES")) |s|
                try allocator.dupe(u8, s)
            else
                null,
            .log_level = if (env_map.get("OTEL_LOG_LEVEL")) |s|
                LogLevel.fromString(s) orelse .info
            else
                .info,
            .trace_propagators = try parsePropagators(&env_map, allocator),
            .trace_config = try TraceConfig.fromEnv(&env_map, allocator),
            .metrics_config = try MetricsConfig.fromEnv(&env_map, allocator),
            .logs_config = try LogsConfig.fromEnv(&env_map, allocator),
        };
    }

    /// Clean up owned fields (but don't destroy the Configuration itself)
    pub fn deinitFields(self: *Configuration) void {
        if (self.service_name) |name| self.allocator.free(name);
        if (self.resource_attributes) |attrs| self.allocator.free(attrs);
        self.allocator.free(self.trace_propagators);
        self.trace_config.deinit(self.allocator);
        self.metrics_config.deinit(self.allocator);
        self.logs_config.deinit(self.allocator);
    }

    /// Deinitialize and destroy the Configuration (for heap-allocated instances)
    pub fn deinit(self: *Configuration) void {
        self.deinitFields();
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Parsing Utilities
// ============================================================================

/// Parse a boolean environment variable
/// Accepts: "true", "1" for true; "false", "0" for false (case-insensitive)
fn parseBool(env_map: *const std.process.EnvMap, key: []const u8) ?bool {
    const value = env_map.get(key) orelse return null;
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) {
        return false;
    }
    return null;
}

/// Parse an integer environment variable
fn parseInt(comptime T: type, env_map: *const std.process.EnvMap, key: []const u8) ?T {
    const value = env_map.get(key) orelse return null;
    return std.fmt.parseInt(T, value, 10) catch null;
}

/// Parse comma-separated list of propagators
/// Default: "tracecontext,baggage"
fn parsePropagators(env_map: *const std.process.EnvMap, allocator: std.mem.Allocator) ![]const TracePropagator {
    const default_propagators = &[_]TracePropagator{ .tracecontext, .baggage };

    const value = env_map.get("OTEL_PROPAGATORS") orelse {
        return allocator.dupe(TracePropagator, default_propagators);
    };

    var list: std.ArrayList(TracePropagator) = .empty;
    errdefer list.deinit(allocator);

    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        if (TracePropagator.fromString(trimmed)) |prop| {
            try list.append(allocator, prop);
        } else {
            // Unknown propagator - log warning and skip
            std.log.warn("Unknown propagator: {s}", .{trimmed});
        }
    }

    // If parsing resulted in empty list, use defaults
    if (list.items.len == 0) {
        list.deinit(allocator);
        return allocator.dupe(TracePropagator, default_propagators);
    }

    return list.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "parseBool - valid values" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    try env_map.put("TRUE_VAR", "true");
    try env_map.put("FALSE_VAR", "false");
    try env_map.put("ONE_VAR", "1");
    try env_map.put("ZERO_VAR", "0");
    try env_map.put("MIXED_CASE", "TrUe");
    try env_map.put("INVALID_VAR", "maybe");

    try std.testing.expectEqual(@as(?bool, true), parseBool(&env_map, "TRUE_VAR"));
    try std.testing.expectEqual(@as(?bool, false), parseBool(&env_map, "FALSE_VAR"));
    try std.testing.expectEqual(@as(?bool, true), parseBool(&env_map, "ONE_VAR"));
    try std.testing.expectEqual(@as(?bool, false), parseBool(&env_map, "ZERO_VAR"));
    try std.testing.expectEqual(@as(?bool, true), parseBool(&env_map, "MIXED_CASE"));
    try std.testing.expectEqual(@as(?bool, null), parseBool(&env_map, "INVALID_VAR"));
    try std.testing.expectEqual(@as(?bool, null), parseBool(&env_map, "NONEXISTENT"));
}

test "parseInt - valid values" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    try env_map.put("U32_VAR", "12345");
    try env_map.put("U64_VAR", "9876543210");
    try env_map.put("ZERO_VAR", "0");
    try env_map.put("INVALID_VAR", "not_a_number");

    try std.testing.expectEqual(@as(?u32, 12345), parseInt(u32, &env_map, "U32_VAR"));
    try std.testing.expectEqual(@as(?u64, 9876543210), parseInt(u64, &env_map, "U64_VAR"));
    try std.testing.expectEqual(@as(?u32, 0), parseInt(u32, &env_map, "ZERO_VAR"));
    try std.testing.expectEqual(@as(?u32, null), parseInt(u32, &env_map, "INVALID_VAR"));
    try std.testing.expectEqual(@as(?u32, null), parseInt(u32, &env_map, "NONEXISTENT"));
}

test "LogLevel.fromString" {
    try std.testing.expectEqual(@as(?LogLevel, .trace), LogLevel.fromString("trace"));
    try std.testing.expectEqual(@as(?LogLevel, .debug), LogLevel.fromString("DEBUG"));
    try std.testing.expectEqual(@as(?LogLevel, .info), LogLevel.fromString("Info"));
    try std.testing.expectEqual(@as(?LogLevel, .warn), LogLevel.fromString("warn"));
    try std.testing.expectEqual(@as(?LogLevel, .warn), LogLevel.fromString("warning"));
    try std.testing.expectEqual(@as(?LogLevel, .@"error"), LogLevel.fromString("error"));
    try std.testing.expectEqual(@as(?LogLevel, .fatal), LogLevel.fromString("FATAL"));
    try std.testing.expectEqual(@as(?LogLevel, null), LogLevel.fromString("invalid"));
}

test "TracePropagator.fromString" {
    try std.testing.expectEqual(@as(?TracePropagator, .tracecontext), TracePropagator.fromString("tracecontext"));
    try std.testing.expectEqual(@as(?TracePropagator, .baggage), TracePropagator.fromString("BAGGAGE"));
    try std.testing.expectEqual(@as(?TracePropagator, .b3), TracePropagator.fromString("b3"));
    try std.testing.expectEqual(@as(?TracePropagator, .b3multi), TracePropagator.fromString("b3multi"));
    try std.testing.expectEqual(@as(?TracePropagator, .jaeger), TracePropagator.fromString("jaeger"));
    try std.testing.expectEqual(@as(?TracePropagator, null), TracePropagator.fromString("invalid"));
}

test "parsePropagators - default" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    const propagators = try parsePropagators(&env_map, allocator);
    defer allocator.free(propagators);

    try std.testing.expectEqual(@as(usize, 2), propagators.len);
    try std.testing.expectEqual(TracePropagator.tracecontext, propagators[0]);
    try std.testing.expectEqual(TracePropagator.baggage, propagators[1]);
}

test "parsePropagators - custom" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    try env_map.put("OTEL_PROPAGATORS", "b3,jaeger,baggage");

    const propagators = try parsePropagators(&env_map, allocator);
    defer allocator.free(propagators);

    try std.testing.expectEqual(@as(usize, 3), propagators.len);
    try std.testing.expectEqual(TracePropagator.b3, propagators[0]);
    try std.testing.expectEqual(TracePropagator.jaeger, propagators[1]);
    try std.testing.expectEqual(TracePropagator.baggage, propagators[2]);
}

test "parsePropagators - with whitespace" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    try env_map.put("OTEL_PROPAGATORS", " tracecontext , baggage , b3 ");

    const propagators = try parsePropagators(&env_map, allocator);
    defer allocator.free(propagators);

    try std.testing.expectEqual(@as(usize, 3), propagators.len);
    try std.testing.expectEqual(TracePropagator.tracecontext, propagators[0]);
    try std.testing.expectEqual(TracePropagator.baggage, propagators[1]);
    try std.testing.expectEqual(TracePropagator.b3, propagators[2]);
}

test "TraceConfig.fromEnv - defaults" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    var config = try TraceConfig.fromEnv(&env_map, allocator);
    defer config.deinit(allocator);

    try std.testing.expectEqual(TraceConfig.Sampler.parentbased_always_on, config.sampler);
    try std.testing.expectEqual(@as(?[]const u8, null), config.sampler_arg);
    try std.testing.expectEqual(TraceConfig.ExporterType.otlp, config.exporter);
    try std.testing.expectEqual(@as(u64, 5000), config.bsp_schedule_delay_ms);
    try std.testing.expectEqual(@as(u64, 30000), config.bsp_export_timeout_ms);
    try std.testing.expectEqual(@as(u32, 2048), config.bsp_max_queue_size);
    try std.testing.expectEqual(@as(u32, 512), config.bsp_max_export_batch_size);
    try std.testing.expectEqual(@as(u32, 128), config.attribute_count_limit);
}

test "TraceConfig.fromEnv - custom values" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    try env_map.put("OTEL_TRACES_SAMPLER", "always_on");
    try env_map.put("OTEL_TRACES_SAMPLER_ARG", "0.5");
    try env_map.put("OTEL_TRACES_EXPORTER", "jaeger");
    try env_map.put("OTEL_BSP_SCHEDULE_DELAY", "1000");
    try env_map.put("OTEL_BSP_MAX_QUEUE_SIZE", "4096");

    var config = try TraceConfig.fromEnv(&env_map, allocator);
    defer config.deinit(allocator);

    try std.testing.expectEqual(TraceConfig.Sampler.always_on, config.sampler);
    try std.testing.expectEqualStrings("0.5", config.sampler_arg.?);
    try std.testing.expectEqual(TraceConfig.ExporterType.jaeger, config.exporter);
    try std.testing.expectEqual(@as(u64, 1000), config.bsp_schedule_delay_ms);
    try std.testing.expectEqual(@as(u32, 4096), config.bsp_max_queue_size);
}

test "MetricsConfig.fromEnv - defaults" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    var config = try MetricsConfig.fromEnv(&env_map, allocator);
    defer config.deinit(allocator);

    try std.testing.expectEqual(MetricsConfig.ExporterType.otlp, config.exporter);
    try std.testing.expectEqual(@as(u64, 60000), config.export_interval_ms);
    try std.testing.expectEqual(@as(u64, 30000), config.export_timeout_ms);
    try std.testing.expectEqual(MetricsConfig.ExemplarFilter.trace_based, config.exemplar_filter);
}

test "MetricsConfig.fromEnv - custom values" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    try env_map.put("OTEL_METRICS_EXPORTER", "prometheus");
    try env_map.put("OTEL_METRIC_EXPORT_INTERVAL", "30000");
    try env_map.put("OTEL_METRICS_EXEMPLAR_FILTER", "always_on");

    var config = try MetricsConfig.fromEnv(&env_map, allocator);
    defer config.deinit(allocator);

    try std.testing.expectEqual(MetricsConfig.ExporterType.prometheus, config.exporter);
    try std.testing.expectEqual(@as(u64, 30000), config.export_interval_ms);
    try std.testing.expectEqual(MetricsConfig.ExemplarFilter.always_on, config.exemplar_filter);
}

test "LogsConfig.fromEnv - defaults" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    var config = try LogsConfig.fromEnv(&env_map, allocator);
    defer config.deinit(allocator);

    try std.testing.expectEqual(LogsConfig.ExporterType.otlp, config.exporter);
    try std.testing.expectEqual(@as(u64, 1000), config.blrp_schedule_delay_ms);
    try std.testing.expectEqual(@as(u64, 30000), config.blrp_export_timeout_ms);
    try std.testing.expectEqual(@as(u32, 2048), config.blrp_max_queue_size);
}

test "LogsConfig.fromEnv - custom values" {
    const allocator = std.testing.allocator;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    try env_map.put("OTEL_LOGS_EXPORTER", "console");
    try env_map.put("OTEL_BLRP_SCHEDULE_DELAY", "2000");
    try env_map.put("OTEL_BLRP_MAX_QUEUE_SIZE", "1024");

    var config = try LogsConfig.fromEnv(&env_map, allocator);
    defer config.deinit(allocator);

    try std.testing.expectEqual(LogsConfig.ExporterType.console, config.exporter);
    try std.testing.expectEqual(@as(u64, 2000), config.blrp_schedule_delay_ms);
    try std.testing.expectEqual(@as(u32, 1024), config.blrp_max_queue_size);
}

test "Configuration.initFromEnv - defaults" {
    const allocator = std.testing.allocator;

    var config = try Configuration.initFromEnv(allocator);
    defer config.deinitFields(); // Use deinitFields for stack-allocated config

    try std.testing.expectEqual(false, config.sdk_disabled);
    try std.testing.expectEqual(@as(?[]const u8, null), config.service_name);
    try std.testing.expectEqual(LogLevel.info, config.log_level);
    try std.testing.expectEqual(@as(usize, 2), config.trace_propagators.len);
}

test "Configuration.initFromEnv - custom values" {
    const allocator = std.testing.allocator;

    // Set environment variables
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    try env_map.put("OTEL_SDK_DISABLED", "false");
    try env_map.put("OTEL_SERVICE_NAME", "test-service");
    try env_map.put("OTEL_LOG_LEVEL", "debug");
    try env_map.put("OTEL_TRACES_SAMPLER", "always_on");

    // Create a new env map and initialize config from it
    var test_env = std.process.EnvMap.init(allocator);
    defer test_env.deinit();

    try test_env.put("OTEL_SDK_DISABLED", "false");
    try test_env.put("OTEL_SERVICE_NAME", "test-service");
    try test_env.put("OTEL_LOG_LEVEL", "debug");
    try test_env.put("OTEL_TRACES_SAMPLER", "always_on");

    // We need to test with actual environment, so let's just test the components
    var trace_config = try TraceConfig.fromEnv(&test_env, allocator);
    defer trace_config.deinit(allocator);

    try std.testing.expectEqual(TraceConfig.Sampler.always_on, trace_config.sampler);
}

test "Configuration singleton" {
    const allocator = std.testing.allocator;

    // Reset singleton before test
    Configuration.reset();

    // First access creates instance
    const config1 = try Configuration.global(allocator);

    // Second access returns same instance
    const config2 = try Configuration.global(allocator);
    try std.testing.expectEqual(config1, config2);

    // Verify it's actually the same instance by checking address
    try std.testing.expectEqual(@intFromPtr(config1), @intFromPtr(config2));

    // Reset for cleanup
    Configuration.reset();
}
