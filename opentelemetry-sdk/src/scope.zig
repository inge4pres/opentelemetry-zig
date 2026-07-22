const std = @import("std");
const Attribute = @import("./attributes.zig").Attribute;
const Attributes = @import("./attributes.zig").Attributes;

/// Instrumentation Scope is a logical unit of the application code with which the emitted telemetry can be associated
/// see: https://opentelemetry.io/docs/specs/otel/glossary/#instrumentation-scope
pub const InstrumentationScope = struct {
    const Self = @This();

    name: []const u8,
    version: ?[]const u8 = null,
    schema_url: ?[]const u8 = null,
    attributes: ?[]Attribute = null,

    pub const HashContext = struct {
        pub fn hash(_: HashContext, self: Self) u64 {
            const hashContext = Attributes.HashContext{};

            const attributesHash = hashContext.hash(Attributes.with(self.attributes));

            var h = std.hash.Wyhash.init(0);

            h.update(self.name);
            h.update(self.schema_url orelse "");
            h.update(self.version orelse "");

            return @mod(h.final(), attributesHash);
        }
        pub fn eql(_: HashContext, a: Self, b: Self) bool {
            const hashContext = Attributes.HashContext{};
            const eqAttributes = hashContext.eql(
                Attributes.with(a.attributes),
                Attributes.with(b.attributes),
            );

            if (!eqAttributes) {
                return false;
            }

            return std.mem.eql(
                u8,
                a.name,
                b.name,
            ) and std.mem.eql(
                u8,
                a.version orelse "",
                b.version orelse "",
            ) and std.mem.eql(
                u8,
                a.schema_url orelse "",
                b.schema_url orelse "",
            );
        }
    };
};

test "InstrumentationScope should hash correctly" {
    const attributes = try Attributes.from(std.testing.allocator, .{ "key", @as(u64, 42), "key2", true });
    defer std.testing.allocator.free(attributes.?);

    const underTest: InstrumentationScope = .{ .name = "aName", .attributes = attributes };

    const hashContext = InstrumentationScope.HashContext{};
    const hash = hashContext.hash(underTest);

    try std.testing.expectEqual(1822844016711720727, hash);
}

test "InstrumentationScope should return two differt hashes for two different instance" {
    const attributes = try Attributes.from(std.testing.allocator, .{ "key", @as(u64, 42), "key2", true });
    defer std.testing.allocator.free(attributes.?);

    const first: InstrumentationScope = .{ .name = "firstInstance", .attributes = attributes };

    const second: InstrumentationScope = .{ .name = "secondInstance", .attributes = attributes };

    const hashContext = InstrumentationScope.HashContext{};

    try std.testing.expect(hashContext.hash(first) != hashContext.hash(second));
}

test "InstrumentationScope should equal correctly" {
    const attributes = try Attributes.from(std.testing.allocator, .{ "key", @as(u64, 42), "key2", true });
    defer std.testing.allocator.free(attributes.?);

    const first: InstrumentationScope = .{ .name = "aName", .attributes = attributes };

    const second: InstrumentationScope = .{ .name = "aName", .attributes = attributes };

    const hashContext = InstrumentationScope.HashContext{};

    try std.testing.expect(hashContext.eql(first, second));
}

test "InstrumentationScope hash should be consistent regardless of attribute order" {
    const allocator = std.testing.allocator;

    const attrs1 = try Attributes.from(allocator, .{ "key1", @as(u64, 42), "key2", true, "key3", @as([]const u8, "value3") });
    defer allocator.free(attrs1.?);

    const attrs2 = try Attributes.from(allocator, .{ "key3", @as([]const u8, "value3"), "key1", @as(u64, 42), "key2", true });
    defer allocator.free(attrs2.?);

    const scope1: InstrumentationScope = .{ .name = "testScope", .attributes = attrs1 };
    const scope2: InstrumentationScope = .{ .name = "testScope", .attributes = attrs2 };

    const hashContext = InstrumentationScope.HashContext{};

    try std.testing.expectEqual(hashContext.hash(scope1), hashContext.hash(scope2));
    try std.testing.expect(hashContext.eql(scope1, scope2));
}
