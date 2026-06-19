const std = @import("std");

const logs = @import("../../../api/logs/logger_provider.zig");
const LogRecordExporter = @import("../log_record_exporter.zig").LogRecordExporter;
const InstrumentationScope = @import("../../../scope.zig").InstrumentationScope;

/// Serializable representation of a log record for export purposes
const SerializableLogRecord = struct {
    timestamp: ?u64,
    observed_timestamp: u64,
    trace_id: ?[16]u8,
    span_id: ?[8]u8,
    severity_number: ?u8,
    severity_text: ?[]const u8,
    body: ?[]const u8,
    scope: InstrumentationScope,

    pub fn fromLogRecord(log_record: logs.ReadableLogRecord) SerializableLogRecord {
        return SerializableLogRecord{
            .timestamp = log_record.timestamp,
            .observed_timestamp = log_record.observed_timestamp,
            .trace_id = log_record.trace_id,
            .span_id = log_record.span_id,
            .severity_number = log_record.severity_number,
            .severity_text = log_record.severity_text,
            .body = log_record.body,
            .scope = log_record.scope,
        };
    }
};

/// GenericWriterExporter is the generic LogRecordExporter that outputs log records to the given writer.
fn GenericWriterExporter(
    comptime Writer: type,
) type {
    return struct {
        writer: Writer,

        const Self = @This();

        pub fn init(writer: Writer) Self {
            return Self{
                .writer = writer,
            };
        }

        fn writerInterface(self: *Self) *std.Io.Writer {
            if (@hasField(Writer, "interface")) {
                return &self.writer.interface;
            }
            if (@hasField(Writer, "writer")) {
                return &self.writer.writer;
            }
            return &self.writer;
        }

        pub fn exportLogs(ctx: *anyopaque, log_records: []logs.ReadableLogRecord) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Convert log records to serializable format
            var serializable_logs: std.ArrayList(SerializableLogRecord) = .empty;
            defer serializable_logs.deinit(std.heap.page_allocator);

            for (log_records) |log_record| {
                try serializable_logs.append(std.heap.page_allocator, SerializableLogRecord.fromLogRecord(log_record));
            }

            // Serialize to JSON - format directly to this writer
            const writer = self.writerInterface();
            try writer.print("{f}", .{std.json.fmt(serializable_logs.items, .{})});
            try writer.flush();
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}

        pub fn asLogRecordExporter(self: *Self) LogRecordExporter {
            return .{
                .ptr = self,
                .vtable = &.{
                    .exportLogsFn = exportLogs,
                    .shutdownFn = shutdown,
                },
            };
        }
    };
}

/// StdoutExporter outputs log records into OS stdout.
/// ref: https://opentelemetry.io/docs/specs/otel/logs/sdk_exporters/stdout/
pub const StdoutExporter = GenericWriterExporter(std.Io.File.Writer);

/// InMemoryExporter exports log records to in-memory buffer.
/// It is designed for testing GenericWriterExporter.
pub const InMemoryExporter = GenericWriterExporter(std.Io.Writer.Allocating);

test "GenericWriterExporter" {
    var out_buf: std.ArrayList(u8) = .empty;
    {
        var inmemory_exporter = InMemoryExporter.init(.fromArrayList(std.testing.allocator, &out_buf));
        errdefer inmemory_exporter.writer.deinit();
        var exporter = inmemory_exporter.asLogRecordExporter();

        // Create a test log record
        const scope = InstrumentationScope{ .name = "test-logger", .version = "1.0.0" };
        var log_record: logs.ReadWriteLogRecord = .{
            .scope = scope,
            .observed_timestamp = 0,
            .body = "test log message",
            .severity_number = 9,
            .severity_text = "INFO",
        };
        defer log_record.deinit(std.testing.allocator);

        const readable = log_record.asReadable();

        var log_records = [_]logs.ReadableLogRecord{readable};
        try exporter.exportLogs(log_records[0..log_records.len]);

        out_buf = inmemory_exporter.writer.toArrayList();
    }
    defer out_buf.deinit(std.testing.allocator);

    // Since JSON output can be complex, just check that something was written
    try std.testing.expect(out_buf.items.len > 0);

    // Assert that the output contains expected log data
    std.debug.assert(std.mem.indexOf(u8, out_buf.items, "test log message") != null);
    std.debug.assert(std.mem.indexOf(u8, out_buf.items, "INFO") != null);
    std.debug.assert(std.mem.indexOf(u8, out_buf.items, "observed_timestamp") != null);
    std.debug.assert(std.mem.indexOf(u8, out_buf.items, "test-logger") != null);
}
