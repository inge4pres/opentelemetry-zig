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
            _ = std.fmt.bufPrint(&buf, "{s}", .{std.fmt.fmtSliceHexLower(&tid)}) catch unreachable;
            break :blk (buf[0..]);
        } else "";

        // Convert span_id to hex string (8 bytes -> 16 char hex)
        const span_id_str: []const u8 = if (log_record.span_id) |sid| blk: {
            var buf: [16]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{s}", .{std.fmt.fmtSliceHexLower(&sid)}) catch unreachable;
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
        const any_value = switch (value) {
            .string => |v| pbcommon.AnyValue{ .value = .{ .string_value = (v) } },
            .bool => |v| pbcommon.AnyValue{ .value = .{ .bool_value = v } },
            .int => |v| pbcommon.AnyValue{ .value = .{ .int_value = v } },
            .double => |v| pbcommon.AnyValue{ .value = .{ .double_value = v } },
        };

        return pbcommon.KeyValue{
            .key = (key),
            .value = any_value,
        };
    }
};
