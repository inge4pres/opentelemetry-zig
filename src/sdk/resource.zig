const std = @import("std");
const Attribute = @import("../attributes.zig").Attribute;
const AttributeValue = @import("../attributes.zig").AttributeValue;
const Configuration = @import("config.zig").Configuration;

/// Build resource attributes from configuration
/// Combines OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES
pub fn buildFromConfig(allocator: std.mem.Allocator, config: *const Configuration) ![]Attribute {
    var attributes: std.ArrayList(Attribute) = .empty;
    errdefer {
        for (attributes.items) |attr| {
            allocator.free(attr.key);
            if (attr.value == .string) {
                allocator.free(attr.value.string);
            }
        }
        attributes.deinit(allocator);
    }

    // Add service.name if configured
    if (config.service_name) |service_name| {
        const key = try allocator.dupe(u8, "service.name");
        const value = try allocator.dupe(u8, service_name);
        try attributes.append(allocator, Attribute{
            .key = key,
            .value = AttributeValue{ .string = value },
        });
    }

    // Parse and add resource attributes
    if (config.resource_attributes) |resource_attrs| {
        try parseResourceAttributes(allocator, resource_attrs, &attributes);
    }

    return try attributes.toOwnedSlice(allocator);
}

/// Parse resource attributes from comma-separated key=value pairs
/// Format: "key1=value1,key2=value2"
fn parseResourceAttributes(
    allocator: std.mem.Allocator,
    attrs_str: []const u8,
    attributes: *std.ArrayList(Attribute),
) !void {
    var iter = std.mem.splitScalar(u8, attrs_str, ',');
    while (iter.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Split on '=' to get key and value
        const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse {
            std.log.warn("Invalid resource attribute (missing '='): {s}", .{trimmed});
            continue;
        };

        const key_part = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
        const value_part = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

        if (key_part.len == 0) {
            std.log.warn("Invalid resource attribute (empty key): {s}", .{trimmed});
            continue;
        }

        const key = try allocator.dupe(u8, key_part);
        errdefer allocator.free(key);

        const value = try allocator.dupe(u8, value_part);
        errdefer allocator.free(value);

        try attributes.append(allocator, Attribute{
            .key = key,
            .value = AttributeValue{ .string = value },
        });
    }
}

/// Free resource attributes
pub fn freeResource(allocator: std.mem.Allocator, resource: []const Attribute) void {
    for (resource) |attr| {
        allocator.free(attr.key);
        if (attr.value == .string) {
            allocator.free(attr.value.string);
        }
    }
    allocator.free(resource);
}

/// Merge two resource attribute slices into a new one.
/// Caller is responsible for freeing the returned slice.
pub fn mergeResources(
    allocator: std.mem.Allocator,
    res1: []const Attribute,
    res2: []const Attribute,
) !?[]Attribute {
    var merged: std.ArrayList(Attribute) = try .initCapacity(allocator, res1.len + res2.len);
    errdefer merged.deinit(allocator);

    for (res1) |attr| {
        merged.appendAssumeCapacity(try Attribute.dupe(allocator, attr));
    }
    for (res2) |attr| {
        merged.appendAssumeCapacity(try Attribute.dupe(allocator, attr));
    }
    if (merged.items.len > 0) return try merged.toOwnedSlice(allocator) else return null;
}

test "buildFromConfig with service name only" {
    const allocator = std.testing.allocator;

    // Create config with service name
    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = "my-service",
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 1), resource.len);
    try std.testing.expectEqualStrings("service.name", resource[0].key);
    try std.testing.expectEqualStrings("my-service", resource[0].value.string);
}

test "buildFromConfig with resource attributes only" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = "key1=value1,key2=value2",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 2), resource.len);
    try std.testing.expectEqualStrings("key1", resource[0].key);
    try std.testing.expectEqualStrings("value1", resource[0].value.string);
    try std.testing.expectEqualStrings("key2", resource[1].key);
    try std.testing.expectEqualStrings("value2", resource[1].value.string);
}

test "buildFromConfig with both service name and resource attributes" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = "test-service",
        .resource_attributes = "deployment.environment=production,host.name=server-1",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 3), resource.len);
    try std.testing.expectEqualStrings("service.name", resource[0].key);
    try std.testing.expectEqualStrings("test-service", resource[0].value.string);
    try std.testing.expectEqualStrings("deployment.environment", resource[1].key);
    try std.testing.expectEqualStrings("production", resource[1].value.string);
    try std.testing.expectEqualStrings("host.name", resource[2].key);
    try std.testing.expectEqualStrings("server-1", resource[2].value.string);
}

test "parseResourceAttributes with whitespace and empty values" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = " key1 = value1 , key2=value2,  ,key3=",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    // Should parse 3 valid attributes (key3 has empty value which is valid)
    try std.testing.expectEqual(@as(usize, 3), resource.len);
    try std.testing.expectEqualStrings("key1", resource[0].key);
    try std.testing.expectEqualStrings("value1", resource[0].value.string);
    try std.testing.expectEqualStrings("key2", resource[1].key);
    try std.testing.expectEqualStrings("value2", resource[1].value.string);
    try std.testing.expectEqualStrings("key3", resource[2].key);
    try std.testing.expectEqualStrings("", resource[2].value.string);
}

test "buildFromConfig with no resource configuration" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    // Should return empty slice
    try std.testing.expectEqual(@as(usize, 0), resource.len);
}
