const std = @import("std");
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;
const Attributes = @import("../../attributes.zig").Attributes;

pub const Logger = struct  {
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

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

};


pub const LoggerProvider = struct {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const loggerProvider = try allocator.create(Self);

        loggerProvider.* = Self{
            .allocator = allocator,
        };

        return loggerProvider;
    }

    pub fn default() !*Self {
        const allocator = gpa.allocator();
        const provider = try allocator.create(Self);

        provider.* = Self{
            .allocator = allocator,
        };

        return provider;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn getLogger(self: *Self, scope: InstrumentationScope) !*Logger {
        return Logger.init(self.allocator, scope);
    }
};


test "logger valid when name is empty" {
    const lp = try LoggerProvider.default();
    defer lp.deinit();

    const lg = try lp.getLogger(.{
        .name = ""
    });

    try std.testing.expectEqual(Logger, @TypeOf(lg.*));
}

test "logger valid when name is empty without memory leak" {
    const lp = try LoggerProvider.init(std.testing.allocator);
    defer lp.deinit();

    const lg = try lp.getLogger(.{
        .name = ""
    });
    defer lg.deinit();

    try std.testing.expectEqual(Logger, @TypeOf(lg.*));
}


test "logger valid with instrumentation scope provided" {
    const lp = try LoggerProvider.init(std.testing.allocator);
    defer lp.deinit();

    const attributes = try Attributes.from(std.testing.allocator,.{
        "key", @as(u64, 1), "secondKey", @as(u64, 2)
    });

    defer std.testing.allocator.free(attributes.?);

    const scope = InstrumentationScope{
        .name = "myLogger",
        .attributes =  attributes,
    };

    const lg = try lp.getLogger(scope);
    defer lg.deinit();

    try std.testing.expectEqualDeep(scope, lg.scope);
}