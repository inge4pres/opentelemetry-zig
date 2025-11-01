const std = @import("std");
const logs = @import("../../../api/logs/logger_provider.zig");
const LogRecordExporter = @import("../log_record_exporter.zig").LogRecordExporter;
const otlp = @import("../../../otlp.zig");
const attribute = @import("../../../attributes.zig");

const proto = @import("opentelemetry-proto");
const pblogs = proto.logs_v1;
const pbcollector_logs = proto.collector_logs_v1;
const pbcommon = proto.common_v1;
const pbresource = proto.resource_v1;

const InstrumentationScope = @import("../../../scope.zig").InstrumentationScope;

const log = std.log.scoped(.otlp_logs_exporter);

/// OTLPExporter exports log data using the OpenTelemetry Protocol (OTLP).
/// This exporter converts log records to OTLP protobuf format and sends them
/// to an OTLP collector endpoint via HTTP.
///
/// See: https://opentelemetry.io/docs/specs/otlp/
/// See: https://opentelemetry.io/docs/specs/otel/logs/sdk/#logrecordexporter
pub const OTLPExporter = struct {
    allocator: std.mem.Allocator,
    config: *otlp.ConfigOptions,

    const Self = @This();

    /// Initialize a new OTLP exporter with the given allocator and configuration.
    /// The config should be initialized with otlp.ConfigOptions.init() and supports
    /// environment variable configuration for endpoint, headers, compression, etc.
    pub fn init(allocator: std.mem.Allocator, config: *otlp.ConfigOptions) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    /// Cleanup and destroy the exporter instance.
    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Return a LogRecordExporter interface for this exporter.
    /// This allows the exporter to be used with log record processors.
    pub fn asLogRecordExporter(self: *Self) LogRecordExporter {
        return LogRecordExporter{
            .ptr = self,
            .vtable = &.{
                .exportLogsFn = exportLogs,
                .shutdownFn = shutdown,
            },
        };
    }

    fn exportLogs(ctx: *anyopaque, log_records: []logs.ReadableLogRecord) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (log_records.len == 0) return;

        // Convert log records to OTLP format
        var request = try self.logsToOTLPRequest(log_records);
        // FIXME: This should be defer request.deinit(self.allocator)
        // when protobuf supports auto-deinit
        defer self.cleanupRequest(&request);

        const otlp_data = otlp.Signal.Data{ .logs = request };

        // Export using the OTLP transport
        return otlp.Export(self.allocator, self.config, otlp_data);
    }

    fn shutdown(_: *anyopaque) anyerror!void {
        // OTLP exporter doesn't require special shutdown
        return;
    }

    fn logsToOTLPRequest(self: *Self, log_records: []logs.ReadableLogRecord) !pbcollector_logs.ExportLogsServiceRequest {
        var resource_logs = std.ArrayList(pblogs.ResourceLogs){};

        // Group log records by instrumentation scope
        var scope_groups = std.HashMap(
            InstrumentationScope,
            std.ArrayList(logs.ReadableLogRecord),
            InstrumentationScope.HashContext,
            std.hash_map.default_max_load_percentage,
        ).init(self.allocator);
        defer {
            var iterator = scope_groups.valueIterator();
            while (iterator.next()) |list| {
                list.deinit(self.allocator);
            }
            scope_groups.deinit();
        }

        // Group log records by their instrumentation scope
        for (log_records) |log_record| {
            const scope_key = log_record.scope;
            const result = try scope_groups.getOrPut(scope_key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(logs.ReadableLogRecord){};
            }
            try result.value_ptr.append(self.allocator, log_record);
        }

        var scope_logs_list = std.ArrayList(pblogs.ScopeLogs){};

        // Convert each scope group to OTLP format
        var scope_iterator = scope_groups.iterator();
        while (scope_iterator.next()) |entry| {
            const scope_log_records = entry.value_ptr.*;

            var otlp_log_records = std.ArrayList(pblogs.LogRecord){};

            // Convert each log record to OTLP format
            for (scope_log_records.items) |log_record| {
                const otlp_log = try self.logRecordToOTLP(log_record);
                try otlp_log_records.append(self.allocator, otlp_log);
            }

            // Create scope information from the first log record's scope
            const scope_info = if (scope_log_records.items.len > 0)
                scope_log_records.items[0].scope
            else
                InstrumentationScope{
                    .name = "unknown",
                    .version = null,
                    .schema_url = null,
                    .attributes = null,
                };

            var scope_attributes = std.ArrayList(pbcommon.KeyValue){};
            if (scope_info.attributes) |attrs| {
                for (attrs) |attr| {
                    const key_value = try attributeToOTLP(attr.key, attr.value);
                    try scope_attributes.append(self.allocator, key_value);
                }
            }

            const scope_log = pblogs.ScopeLogs{
                .scope = pbcommon.InstrumentationScope{
                    .name = (scope_info.name),
                    .version = (scope_info.version orelse ""),
                    .attributes = scope_attributes,
                    .dropped_attributes_count = 0,
                },
                .log_records = otlp_log_records,
                .schema_url = (scope_info.schema_url orelse ""),
            };
            try scope_logs_list.append(self.allocator, scope_log);
        }

        // Build resource from first log record (all share same resource from provider)
        var resource_attributes = std.ArrayList(pbcommon.KeyValue){};
        if (log_records.len > 0) {
            if (log_records[0].resource) |attrs| {
                for (attrs) |attr| {
                    const key_value = try attributeToOTLP(attr.key, attr.value);
                    try resource_attributes.append(self.allocator, key_value);
                }
            }
        }

        const resource_log = pblogs.ResourceLogs{
            .resource = pbresource.Resource{
                .attributes = resource_attributes,
                .dropped_attributes_count = 0,
                .entity_refs = std.ArrayList(pbcommon.EntityRef){},
            },
            .scope_logs = scope_logs_list,
            .schema_url = (""),
        };
        try resource_logs.append(self.allocator, resource_log);

        return pbcollector_logs.ExportLogsServiceRequest{
            .resource_logs = resource_logs,
        };
    }

    fn cleanupRequest(self: *Self, request: *pbcollector_logs.ExportLogsServiceRequest) void {
        // Clean up the ArrayLists we created
        // Note: Manual cleanup is required because protobuf doesn't support auto-deinit yet
        for (request.resource_logs.items) |*resource_log| {
            // Clean up resource attributes
            if (resource_log.resource) |*resource| {
                resource.attributes.deinit(self.allocator);
                resource.entity_refs.deinit(self.allocator);
            }

            for (resource_log.scope_logs.items) |*scope_log| {
                // Clean up scope attributes
                if (scope_log.scope) |*scope| {
                    scope.attributes.deinit(self.allocator);
                }

                // Clean up log records
                for (scope_log.log_records.items) |*log_record| {
                    // Clean up log record attributes
                    log_record.attributes.deinit(self.allocator);
                }
                scope_log.log_records.deinit(self.allocator);
            }
            resource_log.scope_logs.deinit(self.allocator);
        }
        request.resource_logs.deinit(self.allocator);
    }

    fn logRecordToOTLP(self: *Self, log_record: logs.ReadableLogRecord) !pblogs.LogRecord {
        // Convert attributes
        var attributes = std.ArrayList(pbcommon.KeyValue){};
        for (log_record.attributes) |attr| {
            const key_value = try attributeToOTLP(attr.key, attr.value);
            try attributes.append(self.allocator, key_value);
        }

        // Convert trace_id to hex string (16 bytes -> 32 char hex)
        const trace_id_str: []const u8 = if (log_record.trace_id) |tid| blk: {
            var buf: [32]u8 = undefined;
            const hex = std.fmt.bytesToHex(&tid, .lower);
            @memcpy(&buf, &hex);
            break :blk (buf[0..]);
        } else "";

        // Convert span_id to hex string (8 bytes -> 16 char hex)
        const span_id_str: []const u8 = if (log_record.span_id) |sid| blk: {
            var buf: [16]u8 = undefined;
            const hex = std.fmt.bytesToHex(&sid, .lower);
            @memcpy(&buf, &hex);
            break :blk (buf[0..]);
        } else "";

        // Convert body to AnyValue
        const body: ?pbcommon.AnyValue = if (log_record.body) |b|
            pbcommon.AnyValue{ .value = .{ .string_value = (b) } }
        else
            null;

        // Use timestamp if available, otherwise use observed_timestamp
        const time_unix_nano = log_record.timestamp orelse log_record.observed_timestamp;

        return pblogs.LogRecord{
            .time_unix_nano = time_unix_nano,
            .observed_time_unix_nano = log_record.observed_timestamp,
            .severity_number = severityToOTLP(log_record.severity_number),
            .severity_text = (log_record.severity_text orelse ""),
            .body = body,
            .attributes = attributes,
            .dropped_attributes_count = 0,
            .flags = 0, // TODO: Extract from trace context if available
            .trace_id = (trace_id_str),
            .span_id = (span_id_str),
        };
    }

    fn severityToOTLP(severity: ?u8) pblogs.SeverityNumber {
        const sev = severity orelse return .SEVERITY_NUMBER_UNSPECIFIED;
        return switch (sev) {
            1...4 => .SEVERITY_NUMBER_TRACE,
            5...8 => .SEVERITY_NUMBER_DEBUG,
            9...12 => .SEVERITY_NUMBER_INFO,
            13...16 => .SEVERITY_NUMBER_WARN,
            17...20 => .SEVERITY_NUMBER_ERROR,
            21...24 => .SEVERITY_NUMBER_FATAL,
            else => .SEVERITY_NUMBER_UNSPECIFIED,
        };
    }

    fn attributeToOTLP(key: []const u8, value: attribute.AttributeValue) !pbcommon.KeyValue {
        const any_value: ?pbcommon.AnyValue = switch (value) {
            .string => |v| pbcommon.AnyValue{ .value = .{ .string_value = (v) } },
            .bool => |v| pbcommon.AnyValue{ .value = .{ .bool_value = v } },
            .int => |v| pbcommon.AnyValue{ .value = .{ .int_value = v } },
            .double => |v| pbcommon.AnyValue{ .value = .{ .double_value = v } },
            .baggage => unreachable, // Baggage is not a regular attribute
        };

        return pbcommon.KeyValue{
            .key = (key),
            .value = any_value,
        };
    }
};

test "OTLPExporter basic initialization" {
    const allocator = std.testing.allocator;

    var config = try otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    var exporter = try OTLPExporter.init(allocator, config);
    defer exporter.deinit();

    const log_exporter = exporter.asLogRecordExporter();

    // Verify exporter was created successfully by checking allocator
    try std.testing.expect(exporter.allocator.ptr == allocator.ptr);

    // Basic smoke test - export empty array should not crash
    const empty: []logs.ReadableLogRecord = &[_]logs.ReadableLogRecord{};
    try log_exporter.exportLogs(empty);
}

test "Severity number to OTLP enum mapping" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Test null severity
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_UNSPECIFIED, OTLPExporter.severityToOTLP(null));

    // Test TRACE range (1-4)
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_TRACE, OTLPExporter.severityToOTLP(1));
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_TRACE, OTLPExporter.severityToOTLP(4));

    // Test DEBUG range (5-8)
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_DEBUG, OTLPExporter.severityToOTLP(5));
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_DEBUG, OTLPExporter.severityToOTLP(8));

    // Test INFO range (9-12)
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_INFO, OTLPExporter.severityToOTLP(9));
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_INFO, OTLPExporter.severityToOTLP(12));

    // Test WARN range (13-16)
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_WARN, OTLPExporter.severityToOTLP(13));
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_WARN, OTLPExporter.severityToOTLP(16));

    // Test ERROR range (17-20)
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_ERROR, OTLPExporter.severityToOTLP(17));
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_ERROR, OTLPExporter.severityToOTLP(20));

    // Test FATAL range (21-24)
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_FATAL, OTLPExporter.severityToOTLP(21));
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_FATAL, OTLPExporter.severityToOTLP(24));

    // Test out of range
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_UNSPECIFIED, OTLPExporter.severityToOTLP(0));
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_UNSPECIFIED, OTLPExporter.severityToOTLP(25));
}

test "Attribute to OTLP conversion" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Test string attribute
    const string_kv = try OTLPExporter.attributeToOTLP("key", attribute.AttributeValue{ .string = "value" });
    try std.testing.expectEqualStrings("key", string_kv.key);
    try std.testing.expect(string_kv.value != null);
    const string_value = string_kv.value.?;
    try std.testing.expectEqualStrings("value", string_value.value.?.string_value);

    // Test bool attribute
    const bool_kv = try OTLPExporter.attributeToOTLP("flag", attribute.AttributeValue{ .bool = true });
    try std.testing.expectEqualStrings("flag", bool_kv.key);
    try std.testing.expect(bool_kv.value != null);
    const bool_value = bool_kv.value.?;
    try std.testing.expectEqual(true, bool_value.value.?.bool_value);

    // Test int attribute
    const int_kv = try OTLPExporter.attributeToOTLP("count", attribute.AttributeValue{ .int = 42 });
    try std.testing.expectEqualStrings("count", int_kv.key);
    try std.testing.expect(int_kv.value != null);
    const int_value = int_kv.value.?;
    try std.testing.expectEqual(@as(i64, 42), int_value.value.?.int_value);

    // Test double attribute
    const double_kv = try OTLPExporter.attributeToOTLP("ratio", attribute.AttributeValue{ .double = 3.14 });
    try std.testing.expectEqualStrings("ratio", double_kv.key);
    try std.testing.expect(double_kv.value != null);
    const double_value = double_kv.value.?;
    try std.testing.expectEqual(@as(f64, 3.14), double_value.value.?.double_value);
}

test "Log record to OTLP conversion with all fields" {
    const allocator = std.testing.allocator;

    var config = try otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    var exporter = try OTLPExporter.init(allocator, config);
    defer exporter.deinit();

    // Create a complete log record
    const scope = InstrumentationScope{ .name = "test-logger", .version = "1.0.0" };
    const trace_id: [16]u8 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const span_id: [8]u8 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

    const attrs = try allocator.alloc(attribute.Attribute, 2);
    defer allocator.free(attrs);
    attrs[0] = attribute.Attribute{ .key = "key1", .value = .{ .string = "value1" } };
    attrs[1] = attribute.Attribute{ .key = "key2", .value = .{ .int = 123 } };

    const log_record = logs.ReadableLogRecord{
        .timestamp = 1234567890000000000,
        .observed_timestamp = 1234567891000000000,
        .trace_id = trace_id,
        .span_id = span_id,
        .severity_number = 17, // ERROR
        .severity_text = "ERROR",
        .body = "Test log message",
        .attributes = attrs,
        .resource = null,
        .scope = scope,
    };

    var otlp_log = try exporter.logRecordToOTLP(log_record);
    defer otlp_log.attributes.deinit(allocator);

    // Verify conversion
    try std.testing.expectEqual(@as(u64, 1234567890000000000), otlp_log.time_unix_nano);
    try std.testing.expectEqual(@as(u64, 1234567891000000000), otlp_log.observed_time_unix_nano);
    try std.testing.expectEqual(pblogs.SeverityNumber.SEVERITY_NUMBER_ERROR, otlp_log.severity_number);
    try std.testing.expectEqualStrings("ERROR", otlp_log.severity_text);
    try std.testing.expectEqualStrings("Test log message", otlp_log.body.?.value.?.string_value);
    try std.testing.expectEqual(@as(usize, 2), otlp_log.attributes.items.len);
}

test "Log records grouped by instrumentation scope" {
    const allocator = std.testing.allocator;

    var config = try otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    var exporter = try OTLPExporter.init(allocator, config);
    defer exporter.deinit();

    // Create log records with different scopes
    const scope1 = InstrumentationScope{ .name = "lib1", .version = "1.0.0" };
    const scope2 = InstrumentationScope{ .name = "lib2", .version = "2.0.0" };

    var log_records = [_]logs.ReadableLogRecord{
        logs.ReadableLogRecord{
            .timestamp = null,
            .observed_timestamp = 1000000000,
            .trace_id = null,
            .span_id = null,
            .severity_number = 9,
            .severity_text = "INFO",
            .body = "Message from lib1",
            .attributes = &[_]attribute.Attribute{},
            .resource = null,
            .scope = scope1,
        },
        logs.ReadableLogRecord{
            .timestamp = null,
            .observed_timestamp = 2000000000,
            .trace_id = null,
            .span_id = null,
            .severity_number = 17,
            .severity_text = "ERROR",
            .body = "Message from lib2",
            .attributes = &[_]attribute.Attribute{},
            .resource = null,
            .scope = scope2,
        },
        logs.ReadableLogRecord{
            .timestamp = null,
            .observed_timestamp = 3000000000,
            .trace_id = null,
            .span_id = null,
            .severity_number = 9,
            .severity_text = "INFO",
            .body = "Another message from lib1",
            .attributes = &[_]attribute.Attribute{},
            .resource = null,
            .scope = scope1,
        },
    };

    var request = try exporter.logsToOTLPRequest(&log_records);
    defer exporter.cleanupRequest(&request);

    // Verify we have resource logs
    try std.testing.expectEqual(@as(usize, 1), request.resource_logs.items.len);

    const resource_log = request.resource_logs.items[0];

    // Verify we have 2 scope logs (for 2 different scopes)
    try std.testing.expectEqual(@as(usize, 2), resource_log.scope_logs.items.len);

    // Verify scope grouping
    var found_lib1 = false;
    var found_lib2 = false;

    for (resource_log.scope_logs.items) |scope_log| {
        if (scope_log.scope) |scope| {
            if (std.meta.eql(scope.name, ("lib1"))) {
                found_lib1 = true;
                try std.testing.expectEqual(("1.0.0"), scope.version);
                // lib1 should have 2 log records
                try std.testing.expectEqual(@as(usize, 2), scope_log.log_records.items.len);
            } else if (std.meta.eql(scope.name, ("lib2"))) {
                found_lib2 = true;
                try std.testing.expectEqual(("2.0.0"), scope.version);
                // lib2 should have 1 log record
                try std.testing.expectEqual(@as(usize, 1), scope_log.log_records.items.len);
            }
        }
    }

    try std.testing.expect(found_lib1);
    try std.testing.expect(found_lib2);
}

test "Resource attributes in OTLP export" {
    const allocator = std.testing.allocator;

    var config = try otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    var exporter = try OTLPExporter.init(allocator, config);
    defer exporter.deinit();

    const scope = InstrumentationScope{ .name = "test-logger" };

    // Create resource attributes
    const resource_attrs = try allocator.alloc(attribute.Attribute, 2);
    defer allocator.free(resource_attrs);
    resource_attrs[0] = attribute.Attribute{ .key = "service.name", .value = .{ .string = "my-service" } };
    resource_attrs[1] = attribute.Attribute{ .key = "service.version", .value = .{ .string = "1.0.0" } };

    var log_records = [_]logs.ReadableLogRecord{
        logs.ReadableLogRecord{
            .timestamp = null,
            .observed_timestamp = 1000000000,
            .trace_id = null,
            .span_id = null,
            .severity_number = 9,
            .severity_text = "INFO",
            .body = "Test message",
            .attributes = &[_]attribute.Attribute{},
            .resource = resource_attrs,
            .scope = scope,
        },
    };

    var request = try exporter.logsToOTLPRequest(&log_records);
    defer exporter.cleanupRequest(&request);

    // Verify resource attributes
    try std.testing.expectEqual(@as(usize, 1), request.resource_logs.items.len);
    const resource_log = request.resource_logs.items[0];
    try std.testing.expect(resource_log.resource != null);

    const resource = resource_log.resource.?;
    try std.testing.expectEqual(@as(usize, 2), resource.attributes.items.len);

    // Verify service.name attribute
    try std.testing.expectEqualStrings("service.name", resource.attributes.items[0].key);
    try std.testing.expectEqualStrings("my-service", resource.attributes.items[0].value.?.value.?.string_value);
}

test "Trace context hex conversion" {
    const allocator = std.testing.allocator;

    var config = try otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    var exporter = try OTLPExporter.init(allocator, config);
    defer exporter.deinit();

    const scope = InstrumentationScope{ .name = "test-logger" };
    const trace_id: [16]u8 = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    const span_id: [8]u8 = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };

    const log_record = logs.ReadableLogRecord{
        .timestamp = null,
        .observed_timestamp = 1000000000,
        .trace_id = trace_id,
        .span_id = span_id,
        .severity_number = 9,
        .severity_text = "INFO",
        .body = "Test",
        .attributes = &[_]attribute.Attribute{},
        .resource = null,
        .scope = scope,
    };

    var otlp_log = try exporter.logRecordToOTLP(log_record);
    defer otlp_log.attributes.deinit(allocator);

    // Verify hex conversion (lowercase hex without 0x prefix)
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", otlp_log.trace_id);
    try std.testing.expectEqualStrings("0123456789abcdef", otlp_log.span_id);
}

test "Memory cleanup verification" {
    const allocator = std.testing.allocator;

    var config = try otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    var exporter = try OTLPExporter.init(allocator, config);
    defer exporter.deinit();

    const scope = InstrumentationScope{ .name = "test-logger" };

    const attrs = try allocator.alloc(attribute.Attribute, 1);
    defer allocator.free(attrs);
    attrs[0] = attribute.Attribute{ .key = "key", .value = .{ .string = "value" } };

    var log_records = [_]logs.ReadableLogRecord{
        logs.ReadableLogRecord{
            .timestamp = null,
            .observed_timestamp = 1000000000,
            .trace_id = null,
            .span_id = null,
            .severity_number = 9,
            .severity_text = "INFO",
            .body = "Test",
            .attributes = attrs,
            .resource = null,
            .scope = scope,
        },
    };

    var request = try exporter.logsToOTLPRequest(&log_records);
    exporter.cleanupRequest(&request);

    // If there are memory leaks, the test allocator will catch them
    // This test passes if no leaks are detected
}
