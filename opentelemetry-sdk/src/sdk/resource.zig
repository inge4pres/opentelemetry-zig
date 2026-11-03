const std = @import("std");
const Attribute = @import("../attributes.zig").Attribute;
const Configuration = @import("config.zig").Configuration;
const PercentDecodedCommaSeparatedAssignmentIterator = @import("key_value_sequence_iterator.zig").PercentDecodedCommaSeparatedAssignmentIterator;

/// Build resource attributes from configuration
/// Combines OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES
pub fn buildFromConfig(allocator: std.mem.Allocator, config: *const Configuration) ![]Attribute {
    const has_service_name = config.service_name != null;

    // `parseResourceAttributes` reserves its own capacity, so this only covers
    // the service.name entry below: its append then cannot fail and orphan a
    // duped attribute.
    var attributes: std.ArrayList(Attribute) = try .initCapacity(allocator, @intFromBool(has_service_name));
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
        attributes.appendAssumeCapacity(try Attribute.dupe(allocator, .{
            .key = "service.name",
            .value = .{ .string = service_name },
        }));
    }

    // Parse and add resource attributes
    // Skip service.name from resource_attributes if OTEL_SERVICE_NAME is set (it takes precedence)
    if (config.resource_attributes) |resource_attrs| {
        try parseResourceAttributes(allocator, resource_attrs, &attributes, has_service_name);
    }

    return try attributes.toOwnedSlice(allocator);
}

/// Parse resource attributes from comma-separated key=value pairs
/// Format: "key1=value1,key2=value2"
/// Keys and values are percent-decoded according to RFC 3986.
/// If skip_service_name is true, service.name entries will be skipped (OTEL_SERVICE_NAME takes precedence)
fn parseResourceAttributes(
    allocator: std.mem.Allocator,
    attrs_str: []const u8,
    attributes: *std.ArrayList(Attribute),
    skip_service_name: bool,
) !void {
    // At most one attribute per entry, and a comma-separated list holds at most
    // one more entry than it has commas. Reserving up front makes the appends
    // below infallible, so a duped attribute is never orphaned mid-append.
    try attributes.ensureUnusedCapacity(allocator, std.mem.countScalar(u8, attrs_str, ',') + 1);

    // Decoding never grows a string, so `attrs_str.len` bytes is always enough
    // room for the decoded name and value of any one entry.
    const scratch = try allocator.alloc(u8, attrs_str.len);
    defer allocator.free(scratch);

    var iter: PercentDecodedCommaSeparatedAssignmentIterator = .init(attrs_str, scratch);
    while (iter.next() catch unreachable) |entry| {
        const value = entry.value orelse {
            std.log.warn("Invalid resource attribute (missing '='): {s}", .{entry.name});
            continue;
        };

        if (entry.name.len == 0) {
            std.log.warn("Invalid resource attribute (empty key): ={s}", .{value});
            continue;
        }

        // Skip service.name if OTEL_SERVICE_NAME is set (it takes precedence)
        if (skip_service_name and std.mem.eql(u8, entry.name, "service.name")) continue;

        attributes.appendAssumeCapacity(try Attribute.dupe(allocator, .{
            .key = entry.name,
            .value = .{ .string = value },
        }));
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

fn containsAttributeKey(slice: []const Attribute, key: []const u8) bool {
    for (slice) |attr| {
        if (std.mem.eql(u8, attr.key, key)) return true;
    }
    return false;
}

/// Merge two resource attribute slices into a new one.
/// If a key exists in both slices, the attribute from res1 takes precedence.
/// Caller is responsible for freeing the returned slice with freeResource.
pub fn mergeResources(
    allocator: std.mem.Allocator,
    res1: []const Attribute,
    res2: []const Attribute,
) !?[]Attribute {
    var merged: std.ArrayList(Attribute) = try .initCapacity(allocator, res1.len + res2.len);
    errdefer {
        for (merged.items) |attr| {
            allocator.free(attr.key);
            if (attr.value == .string) {
                allocator.free(attr.value.string);
            }
        }
        merged.deinit(allocator);
    }

    for (res1) |attr| {
        if (!containsAttributeKey(merged.items, attr.key)) {
            merged.appendAssumeCapacity(try Attribute.dupe(allocator, attr));
        }
    }
    for (res2) |attr| {
        if (!containsAttributeKey(merged.items, attr.key)) {
            merged.appendAssumeCapacity(try Attribute.dupe(allocator, attr));
        }
    }

    if (merged.items.len > 0) {
        return try merged.toOwnedSlice(allocator);
    } else {
        merged.deinit(allocator);
        return null;
    }
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

test "OTEL_SERVICE_NAME overrides service.name from OTEL_RESOURCE_ATTRIBUTES" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = "override-service",
        .resource_attributes = "service.name=original-service,key1=value1",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    // Should have 2 attributes: service.name (override) and key1
    try std.testing.expectEqual(@as(usize, 2), resource.len);

    // service.name should be from OTEL_SERVICE_NAME
    try std.testing.expectEqualStrings("service.name", resource[0].key);
    try std.testing.expectEqualStrings("override-service", resource[0].value.string);

    // key1 should be from OTEL_RESOURCE_ATTRIBUTES
    try std.testing.expectEqualStrings("key1", resource[1].key);
    try std.testing.expectEqualStrings("value1", resource[1].value.string);
}

test "service.name from OTEL_RESOURCE_ATTRIBUTES when OTEL_SERVICE_NAME not set" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = "service.name=from-resource-attrs,key1=value1",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    // Should have 2 attributes
    try std.testing.expectEqual(@as(usize, 2), resource.len);

    // service.name should be from OTEL_RESOURCE_ATTRIBUTES
    try std.testing.expectEqualStrings("service.name", resource[0].key);
    try std.testing.expectEqualStrings("from-resource-attrs", resource[0].value.string);

    try std.testing.expectEqualStrings("key1", resource[1].key);
    try std.testing.expectEqualStrings("value1", resource[1].value.string);
}

test "service.name from OTEL_RESOURCE_ATTRIBUTES survives resource building" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_RESOURCE_ATTRIBUTES", "service.name=checkout,host.name=server-1");

    const config = try Configuration.init(allocator, std.testing.io, &env_map);
    defer config.deinit();

    const resource = try buildFromConfig(allocator, config);
    defer freeResource(allocator, resource);

    // service.name is resolved once in the configuration, so it is emitted exactly once.
    try std.testing.expectEqual(@as(usize, 2), resource.len);
    try std.testing.expectEqualStrings("service.name", resource[0].key);
    try std.testing.expectEqualStrings("checkout", resource[0].value.string);
    try std.testing.expectEqualStrings("host.name", resource[1].key);
    try std.testing.expectEqualStrings("server-1", resource[1].value.string);
}

test "service.name defaults to unknown_service when nothing is configured" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const config = try Configuration.init(allocator, std.testing.io, &env_map);
    defer config.deinit();

    const resource = try buildFromConfig(allocator, config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 1), resource.len);
    try std.testing.expectEqualStrings("service.name", resource[0].key);
    try std.testing.expect(std.mem.startsWith(u8, resource[0].value.string, "unknown_service"));
}

test "mergeResources with distinct attributes" {
    const allocator = std.testing.allocator;

    const res1 = [_]Attribute{
        .{ .key = "service.name", .value = .{ .string = "auth-service" } },
        .{ .key = "service.version", .value = .{ .string = "1.0.0" } },
    };
    const res2 = [_]Attribute{
        .{ .key = "deployment.environment", .value = .{ .string = "production" } },
    };

    const merged = (try mergeResources(allocator, &res1, &res2)).?;
    defer freeResource(allocator, merged);

    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("service.name", merged[0].key);
    try std.testing.expectEqualStrings("auth-service", merged[0].value.string);
    try std.testing.expectEqualStrings("service.version", merged[1].key);
    try std.testing.expectEqualStrings("1.0.0", merged[1].value.string);
    try std.testing.expectEqualStrings("deployment.environment", merged[2].key);
    try std.testing.expectEqualStrings("production", merged[2].value.string);
}

test "mergeResources deduplicates keys with res1 precedence" {
    const allocator = std.testing.allocator;

    const res1 = [_]Attribute{
        .{ .key = "service.name", .value = .{ .string = "custom-service" } },
        .{ .key = "host.name", .value = .{ .string = "primary-host" } },
    };
    const res2 = [_]Attribute{
        .{ .key = "service.name", .value = .{ .string = "default-service" } },
        .{ .key = "region", .value = .{ .string = "us-east-1" } },
    };

    const merged = (try mergeResources(allocator, &res1, &res2)).?;
    defer freeResource(allocator, merged);

    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("service.name", merged[0].key);
    try std.testing.expectEqualStrings("custom-service", merged[0].value.string);
    try std.testing.expectEqualStrings("host.name", merged[1].key);
    try std.testing.expectEqualStrings("primary-host", merged[1].value.string);
    try std.testing.expectEqualStrings("region", merged[2].key);
    try std.testing.expectEqualStrings("us-east-1", merged[2].value.string);
}

test "mergeResources with empty inputs" {
    const allocator = std.testing.allocator;

    const empty: []const Attribute = &.{};
    const merged = try mergeResources(allocator, empty, empty);
    try std.testing.expect(merged == null);
}

test "mergeResources cleanup on allocation failure does not leak" {
    const res1 = [_]Attribute{
        .{ .key = "k1", .value = .{ .string = "v1" } },
        .{ .key = "k2", .value = .{ .string = "v2" } },
    };
    const res2 = [_]Attribute{
        .{ .key = "k3", .value = .{ .string = "v3" } },
    };

    // Test failure at each allocation step to verify no memory leak occurs
    for (1..7) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing.allocator();

        _ = mergeResources(allocator, &res1, &res2) catch {};
    }
}

test "parseResourceAttributes percent-decodes keys and values" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = "deployment.environment=prod%20east,custom%2Etag=val%2C1,equation=a%3Db,path=%2Fvar%2Flog,math=1+1,literal%2=kept",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 6), resource.len);
    try std.testing.expectEqualStrings("deployment.environment", resource[0].key);
    try std.testing.expectEqualStrings("prod east", resource[0].value.string);

    try std.testing.expectEqualStrings("custom.tag", resource[1].key);
    try std.testing.expectEqualStrings("val,1", resource[1].value.string);

    try std.testing.expectEqualStrings("equation", resource[2].key);
    try std.testing.expectEqualStrings("a=b", resource[2].value.string);

    try std.testing.expectEqualStrings("path", resource[3].key);
    try std.testing.expectEqualStrings("/var/log", resource[3].value.string);

    try std.testing.expectEqualStrings("math", resource[4].key);
    try std.testing.expectEqualStrings("1+1", resource[4].value.string);

    try std.testing.expectEqualStrings("literal%2", resource[5].key);
    try std.testing.expectEqualStrings("kept", resource[5].value.string);
}

test "service.name percent-decoded from OTEL_RESOURCE_ATTRIBUTES in Configuration.init" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_RESOURCE_ATTRIBUTES", "service.name=my%20special%20service,host=localhost");

    const config = try Configuration.init(allocator, std.testing.io, &env_map);
    defer config.deinit();

    try std.testing.expectEqualStrings("my special service", config.service_name.?);

    const resource = try buildFromConfig(allocator, config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 2), resource.len);
    try std.testing.expectEqualStrings("service.name", resource[0].key);
    try std.testing.expectEqualStrings("my special service", resource[0].value.string);
    try std.testing.expectEqualStrings("host", resource[1].key);
    try std.testing.expectEqualStrings("localhost", resource[1].value.string);
}
