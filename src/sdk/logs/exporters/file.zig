//! OTLP File exporter for logs.
//!
//! This exporter uses the generic OTLP file exporter to write log data
//! to a file in JSON Lines format.

const std = @import("std");

const log = std.log.scoped(.file_exporter);

const logs = @import("../../../api/logs/logger_provider.zig");
const Resource = @import("../../../resource.zig").Resource;

const LogRecordExporter = @import("../log_record_exporter.zig").LogRecordExporter;

const otlp = @import("../../../otlp.zig");
const pblogs = @import("opentelemetry-proto").logs_v1;
const pbcollector_logs = @import("opentelemetry-proto").collector_logs_v1;

// Import the conversion functions from the OTLP exporter
const otlp_exporter = @import("otlp.zig");
const toProtobufLogRecord = otlp_exporter.toProtobufLogRecord;
const toProtobufResource = otlp_exporter.toProtobufResource;

/// File exporter for logs using OTLP JSON Lines format.
pub const FileExporter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    resource: Resource,
    file: std.fs.File,
    owns_file: bool,

    pub const Options = struct {
        /// Path to the output file. If null, writes to stdout.
        file_path: ?[]const u8 = null,
        /// If true and file exists, append to it. Otherwise truncate.
        append: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, resource: Resource, options: Options) !Self {
        const file = if (options.file_path) |path| blk: {
            const flags: std.fs.File.CreateFlags = if (options.append)
                .{ .read = true, .truncate = false }
            else
                .{ .read = true, .truncate = true };
            break :blk try std.fs.cwd().createFile(path, flags);
        } else std.io.getStdOut();

        return Self{
            .allocator = allocator,
            .resource = resource,
            .file = file,
            .owns_file = options.file_path != null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.owns_file) {
            self.file.close();
        }
    }

    pub fn logRecordExporter(self: *Self) LogRecordExporter {
        return LogRecordExporter{
            .ptr = self,
            .vtable = &.{
                .exportLogsFn = exportLogs,
                .shutdownFn = shutdown,
            },
        };
    }

    pub fn exportLogs(ctx: *anyopaque, log_records: []logs.ReadableLogRecord) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Convert log records to OTLP protobuf format
        var pb_logs = std.ArrayList(pblogs.LogRecord).init(self.allocator);
        defer pb_logs.deinit();

        for (log_records) |log_record| {
            const pb_log = try toProtobufLogRecord(self.allocator, log_record);
            try pb_logs.append(pb_log);
        }

        // Build scope logs
        var scope_logs = std.ArrayList(pblogs.ScopeLogs).init(self.allocator);
        defer scope_logs.deinit();

        try scope_logs.append(pblogs.ScopeLogs{
            .scope = .{
                .name = "",
                .version = "",
            },
            .log_records = pb_logs,
            .schema_url = "",
        });

        // Build resource logs
        const pb_resource = try toProtobufResource(self.allocator, self.resource);

        var resource_logs = std.ArrayList(pblogs.ResourceLogs).init(self.allocator);
        defer resource_logs.deinit();

        try resource_logs.append(pblogs.ResourceLogs{
            .resource = pb_resource,
            .scope_logs = scope_logs,
            .schema_url = "",
        });

        var service_req = pbcollector_logs.ExportLogsServiceRequest{
            .resource_logs = resource_logs,
        };
        defer service_req.deinit(self.allocator);

        // Wrap in OTLP Signal.Data
        const signal_data = otlp.Signal.Data{
            .logs = service_req,
        };

        // Write using the OTLP ExportFile function
        try otlp.ExportFile(self.allocator, signal_data, &self.file);
    }

    pub fn shutdown(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.owns_file) {
            self.file.close();
        }
    }
};

test "FileExporter init and deinit" {
    const allocator = std.testing.allocator;

    var file_exporter = try FileExporter.init(allocator, Resource.empty(), .{});
    defer file_exporter.deinit();
}
