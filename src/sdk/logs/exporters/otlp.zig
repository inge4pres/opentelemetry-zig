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
        _ = self;
        _ = log_records;
        // TODO: Implement in next commit
        return pbcollector_logs.ExportLogsServiceRequest{
            .resource_logs = std.ArrayList(pblogs.ResourceLogs){},
        };
    }

    fn cleanupRequest(self: *Self, request: *pbcollector_logs.ExportLogsServiceRequest) void {
        _ = self;
        _ = request;
        // TODO: Implement in commit 5
    }
};
