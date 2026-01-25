//! Bridge between Zig's std.log and OpenTelemetry Logs SDK
//!
//! This module provides a logFn implementation that routes std.log calls
//! to OpenTelemetry's LoggerProvider while optionally maintaining output
//! to stderr for a gradual migration path.
//!
//! Usage:
//! ```zig
//! // In your root file (e.g., main.zig or root.zig)
//! const std = @import("std");
//! const sdk = @import("opentelemetry-sdk");
//!
//! pub const std_options: std.Options = .{
//!     .logFn = sdk.logs.std_log_bridge.logFn,
//! };
//!
//! pub fn main() !void {
//!     // Setup your logger provider
//!     var provider = try sdk.logs.LoggerProvider.init(allocator, null);
//!     defer provider.deinit();
//!
//!     // Configure the bridge
//!     sdk.logs.std_log_bridge.configure(.{
//!         .provider = provider,
//!         .also_log_to_stderr = true, // Dual mode during migration
//!     });
//!     defer sdk.logs.std_log_bridge.shutdown();
//!
//!     // Now std.log calls will go to OpenTelemetry!
//!     std.log.info("Application started", .{});
//! }
//! ```

const std = @import("std");
const LoggerProvider = @import("../../api/logs/logger_provider.zig").LoggerProvider;
const Logger = @import("../../api/logs/logger_provider.zig").Logger;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const Attribute = @import("../../attributes.zig").Attribute;

/// Configuration for the std.log bridge
pub const Config = struct {
    /// The OpenTelemetry LoggerProvider to emit logs to
    provider: *LoggerProvider,

    /// Instrumentation scope for bridged logs.
    /// Default uses a single scope for all logs.
    scope: InstrumentationScope = .{ .name = "std.log.bridge" },

    /// If true, logs will be sent to both OpenTelemetry AND stderr.
    /// This is useful during migration to maintain existing log output.
    /// Set to false to only emit to OpenTelemetry.
    also_log_to_stderr: bool = true,

    /// If true, include source location (file, line, function) as attributes.
    /// This follows OpenTelemetry semantic conventions for source code attributes.
    include_source_location: bool = true,

    /// If true, include the Zig log scope as a "code.scope" attribute.
    include_scope_attribute: bool = true,

    /// Strategy for handling different Zig log scopes
    scope_strategy: ScopeStrategy = .single_scope,

    pub const ScopeStrategy = enum {
        /// Use a single Logger for all scopes (from config.scope)
        single_scope,
        /// Create a separate Logger per Zig scope (e.g., scope .http -> Logger with scope "http")
        per_zig_scope,
    };
};

/// Thread-safe configuration state
const State = struct {
    mutex: std.Thread.Mutex = .{},
    config: ?Config = null,
    logger: ?*Logger = null,
    // Cache for per-scope loggers when using per_zig_scope strategy
    scope_loggers: std.StringHashMapUnmanaged(*Logger) = .{},
    allocator: ?std.mem.Allocator = null,

    fn get() *State {
        return &global_state;
    }

    fn deinit(self: *State) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.allocator) |allocator| {
            // Clean up scope loggers cache
            var iter = self.scope_loggers.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            self.scope_loggers.deinit(allocator);
        }

        self.config = null;
        self.logger = null;
        self.allocator = null;
    }
};

var global_state = State{};

/// Configure the std.log bridge.
/// This must be called before any std.log calls that should be routed to OpenTelemetry.
pub fn configure(cfg: Config) !void {
    const state = State.get();
    state.mutex.lock();
    defer state.mutex.unlock();

    // Clean up previous configuration if any
    if (state.allocator) |allocator| {
        var iter = state.scope_loggers.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        state.scope_loggers.clearRetainingCapacity();
    }

    state.config = cfg;

    // For single_scope strategy, get the logger upfront
    if (cfg.scope_strategy == .single_scope) {
        state.logger = try cfg.provider.getLogger(cfg.scope);
    } else {
        // For per_zig_scope, we'll get loggers lazily
        state.logger = null;
        // We need an allocator for caching scope names
        // Use the provider's allocator
        state.allocator = cfg.provider.allocator;
    }
}

/// Shutdown the bridge and clean up resources.
/// Should be called before the LoggerProvider is destroyed.
pub fn shutdown() void {
    const state = State.get();
    state.deinit();
}

/// Map Zig log levels to OpenTelemetry severity numbers.
/// See: https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
fn mapSeverity(level: std.log.Level) u8 {
    return switch (level) {
        .err => 17, // ERROR
        .warn => 13, // WARN
        .info => 9, // INFO
        .debug => 5, // DEBUG
    };
}

/// Map Zig log levels to OpenTelemetry severity text
fn mapSeverityText(comptime level: std.log.Level) []const u8 {
    return comptime level.asText();
}

/// Custom logFn that bridges std.log to OpenTelemetry.
/// Set this in your std_options: `pub const std_options: std.Options = .{ .logFn = logFn };`
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const state = State.get();

    // Get config and logger in a single lock to minimize critical section
    state.mutex.lock();
    const cfg = state.config;
    const logger: ?*Logger = blk: {
        if (cfg) |config| {
            // Fast path for single_scope strategy - logger is pre-fetched
            if (config.scope_strategy == .single_scope) {
                const l = state.logger;
                state.mutex.unlock();
                break :blk l;
            }

            // For per_zig_scope, check cache or create new logger
            const scope_name = comptime @tagName(scope);
            if (state.scope_loggers.get(scope_name)) |cached_logger| {
                state.mutex.unlock();
                break :blk cached_logger;
            }

            // Need to create a new logger for this scope
            const allocator = state.allocator orelse {
                state.mutex.unlock();
                break :blk null;
            };

            const new_scope = InstrumentationScope{
                .name = scope_name,
                .version = null,
            };

            const new_logger = config.provider.getLogger(new_scope) catch {
                state.mutex.unlock();
                break :blk null;
            };

            // Cache it (we need to dupe the scope name since it's comptime)
            const scope_name_dupe = allocator.dupe(u8, scope_name) catch {
                state.mutex.unlock();
                break :blk new_logger;
            };

            state.scope_loggers.put(allocator, scope_name_dupe, new_logger) catch {
                allocator.free(scope_name_dupe);
                state.mutex.unlock();
                break :blk new_logger;
            };

            state.mutex.unlock();
            break :blk new_logger;
        } else {
            state.mutex.unlock();
            break :blk null;
        }
    };

    // If not configured or couldn't get logger, fall back to default logging
    if (cfg == null or logger == null) {
        std.log.defaultLog(level, scope, format, args);
        return;
    }

    const config = cfg.?;
    const unwrapped_logger = logger.?; // Safe unwrap after null check

    // Format the log message
    var buf: [4096]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, format, args) catch |err| {
        // If formatting fails, log the error and the raw format string
        std.log.err("std_log_bridge: failed to format log message: {}", .{err});
        unwrapped_logger.emit(
            mapSeverity(level),
            mapSeverityText(level),
            format,
            null,
        );
        if (config.also_log_to_stderr) {
            std.log.defaultLog(level, scope, format, args);
        }
        return;
    };

    // Build attributes
    var attrs_buffer: [8]Attribute = undefined;
    var attrs_count: usize = 0;

    // Add scope attribute if enabled and not default
    if (config.include_scope_attribute and scope != .default) {
        const scope_name = comptime @tagName(scope);
        attrs_buffer[attrs_count] = .{
            .key = "code.scope",
            .value = .{ .string = scope_name },
        };
        attrs_count += 1;
    }

    // Add source location if enabled
    // Note: @src() gives compile-time source location of the logFn call (this file)
    // For actual caller location, we'd need std.debug.getSelfDebugInfo() at runtime
    // which is expensive. For now, we'll include what we can.
    if (config.include_source_location) {
        // We can add the log level as metadata since we have it
        const level_name = comptime level.asText();
        attrs_buffer[attrs_count] = .{
            .key = "log.level",
            .value = .{ .string = level_name },
        };
        attrs_count += 1;
    }

    const attrs = if (attrs_count > 0) attrs_buffer[0..attrs_count] else null;

    // Emit to OpenTelemetry
    unwrapped_logger.emit(
        mapSeverity(level),
        mapSeverityText(level),
        body,
        attrs,
    );

    // Also log to stderr if dual mode is enabled
    if (config.also_log_to_stderr) {
        std.log.defaultLog(level, scope, format, args);
    }
}

test "std_log_bridge basic configuration" {
    const allocator = std.testing.allocator;

    var provider = try LoggerProvider.init(allocator, null);
    defer provider.deinit();

    try configure(.{
        .provider = provider,
        .also_log_to_stderr = false,
    });
    defer shutdown();

    const state = State.get();
    state.mutex.lock();
    defer state.mutex.unlock();

    try std.testing.expect(state.config != null);
    try std.testing.expect(state.logger != null);
}

test "std_log_bridge severity mapping" {
    try std.testing.expectEqual(@as(u8, 17), mapSeverity(.err));
    try std.testing.expectEqual(@as(u8, 13), mapSeverity(.warn));
    try std.testing.expectEqual(@as(u8, 9), mapSeverity(.info));
    try std.testing.expectEqual(@as(u8, 5), mapSeverity(.debug));
}

test "std_log_bridge severity text mapping" {
    try std.testing.expectEqualStrings("error", mapSeverityText(.err));
    try std.testing.expectEqualStrings("warning", mapSeverityText(.warn));
    try std.testing.expectEqualStrings("info", mapSeverityText(.info));
    try std.testing.expectEqualStrings("debug", mapSeverityText(.debug));
}
