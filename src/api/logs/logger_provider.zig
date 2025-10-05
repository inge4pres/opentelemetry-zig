const std = @import("std");

const Attributes = @import("../../attributes.zig").Attributes;
const Attribute = @import("../../attributes.zig").Attribute;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

pub const LogRecord = struct {
    timestamp: ?u64,
    observed_timestamp: ?u64,
    trace_id: ?[16]u8,
    span_id: ?[8]u8,
    severity_number: ?u8,
    severity_text: ?[]const u8,
    body: ?[]const u8,
    attributes: ?[]const Attribute,
    event_name: ?[]const u8,
};

/// Logger is responsible for emitting logs as LogRecords.
/// see: https://opentelemetry.io/docs/specs/otel/logs/api/#logger
pub const Logger = struct {
    allocator: std.mem.Allocator,
    scope: InstrumentationScope,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, scope: InstrumentationScope) !*Self {
        const logger = try allocator.create(Self);

        logger.* = Self{
            .allocator = allocator,
            .scope = scope,
        };

        return logger;
    }

    pub fn emit(
        _: ?[]const u8,

    ) void {

    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }
};

/// LoggerProvider is the entry point of the API. It provides access to Loggers
/// see: https://opentelemetry.io/docs/specs/otel/logs/api/#loggerprovider
pub const LoggerProvider = struct {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    allocator: std.mem.Allocator,
    loggers: std.HashMap(
        InstrumentationScope,
        *Logger,
        InstrumentationScope.HashContext,
        std.hash_map.default_max_load_percentage,
    ),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const loggerProvider = try allocator.create(Self);

        loggerProvider.* = Self{ .allocator = allocator, .loggers = std.HashMap(
            InstrumentationScope,
            *Logger,
            InstrumentationScope.HashContext,
            std.hash_map.default_max_load_percentage,
        ).init(allocator) };

        return loggerProvider;
    }

    pub fn default() !*Self {
        const allocator = gpa.allocator();
        const provider = try allocator.create(Self);

        provider.* = Self{ .allocator = allocator, .loggers = std.HashMap(
            InstrumentationScope,
            *Logger,
            InstrumentationScope.HashContext,
            std.hash_map.default_max_load_percentage,
        ).init(allocator) };

        return provider;
    }

    pub fn deinit(self: *Self) void {
        self.loggers.deinit();
        self.allocator.destroy(self);
    }

    pub fn getLogger(self: *Self, scope: InstrumentationScope) !*Logger {
        if (self.loggers.get(scope)) |logger| {
            return logger;
        }

        const instance = try Logger.init(self.allocator, scope);
        try self.loggers.put(scope, instance);

        return instance;
    }
};

test "logger valid when name is empty" {
    const lp = try LoggerProvider.default();
    defer lp.deinit();

    const lg = try lp.getLogger(.{ .name = "" });

    try std.testing.expectEqual(Logger, @TypeOf(lg.*));
}

test "logger valid when name is empty without memory leak" {
    const lp = try LoggerProvider.init(std.testing.allocator);
    defer lp.deinit();

    const lg = try lp.getLogger(.{ .name = "" });
    defer lg.deinit();

    try std.testing.expectEqual(Logger, @TypeOf(lg.*));
}

test "logger valid with instrumentation scope provided" {
    const lp = try LoggerProvider.init(std.testing.allocator);
    defer lp.deinit();

    const attributes = try Attributes.from(std.testing.allocator, .{ "key", @as(u64, 1), "secondKey", @as(u64, 2) });

    defer std.testing.allocator.free(attributes.?);

    const scope = InstrumentationScope{
        .name = "myLogger",
        .attributes = attributes,
    };

    const lg = try lp.getLogger(scope);
    defer lg.deinit();

    try std.testing.expectEqualDeep(scope, lg.scope);
}

test "logger exactly the same when getting one with same scope" {
    const lp = try LoggerProvider.init(std.testing.allocator);
    defer lp.deinit();

    const attributes = try Attributes.from(std.testing.allocator, .{ "key", @as(u64, 1), "secondKey", @as(u64, 2) });

    defer std.testing.allocator.free(attributes.?);

    const scope = InstrumentationScope{
        .name = "myLogger",
        .attributes = attributes,
    };

    const lg = try lp.getLogger(scope);
    defer lg.deinit();

    const lg2 = try lp.getLogger(scope);

    try std.testing.expectEqualDeep(lg, lg2);
}
