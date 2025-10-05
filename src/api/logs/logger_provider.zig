const std = @import("std");

const Attributes = @import("../../attributes.zig").Attributes;
const Attribute = @import("../../attributes.zig").Attribute;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

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
    resource: ?*const anyopaque,
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
    resource: ?*const anyopaque,
    scope: InstrumentationScope,

    const Self = @This();

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.attributes);
    }
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

test "ReadWriteLogRecord init and deinit" {
    const allocator = std.testing.allocator;
    const scope = InstrumentationScope{ .name = "test-logger" };

    var log_record = ReadWriteLogRecord.init(allocator, scope);
    defer log_record.deinit(allocator);

    try std.testing.expectEqual(scope, log_record.scope);
    try std.testing.expect(log_record.observed_timestamp > 0);
}

test "ReadWriteLogRecord setAttribute" {
    const allocator = std.testing.allocator;
    const scope = InstrumentationScope{ .name = "test-logger" };

    var log_record = ReadWriteLogRecord.init(allocator, scope);
    defer log_record.deinit(allocator);

    const attr = Attribute{ .key = "test.key", .value = .{ .string = "test.value" } };
    try log_record.setAttribute(allocator, attr);

    try std.testing.expectEqual(@as(usize, 1), log_record.attributes.items.len);
    try std.testing.expectEqualStrings("test.key", log_record.attributes.items[0].key);
}

test "ReadWriteLogRecord to ReadableLogRecord conversion" {
    const allocator = std.testing.allocator;
    const scope = InstrumentationScope{ .name = "test-logger" };

    var rw_record = ReadWriteLogRecord.init(allocator, scope);
    defer rw_record.deinit(allocator);

    rw_record.body = "test message";
    rw_record.severity_number = 9;

    const attr = Attribute{ .key = "test.key", .value = .{ .string = "test.value" } };
    try rw_record.setAttribute(allocator, attr);

    const readable = try rw_record.toReadable(allocator);
    defer readable.deinit(allocator);

    try std.testing.expectEqualStrings("test message", readable.body.?);
    try std.testing.expectEqual(@as(u8, 9), readable.severity_number.?);
    try std.testing.expectEqual(@as(usize, 1), readable.attributes.len);
    try std.testing.expectEqualStrings("test.key", readable.attributes[0].key);
}
