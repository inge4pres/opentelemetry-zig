const logs = @import("../../api/logs/logger_provider.zig");

/// LogRecordExporter defines the interface that protocol-specific exporters must implement.
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#logrecordexporter
pub const LogRecordExporter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    /// VTable defines the methods that the LogRecordExporter's instance must implement.
    pub const VTable = struct {
        /// exportLogs is the method that exports a batch of log records.
        /// This is called synchronously by the processor.
        /// Exporters should complete quickly to avoid blocking emission.
        exportLogsFn: *const fn (
            ctx: *anyopaque,
            log_records: []logs.ReadableLogRecord,
        ) anyerror!void,

        /// shutdown shuts down the exporter.
        /// Should be called exactly once per exporter instance.
        shutdownFn: *const fn (ctx: *anyopaque) anyerror!void,
    };

    /// Export a batch of log records
    pub fn exportLogs(
        self: Self,
        log_records: []logs.ReadableLogRecord,
    ) anyerror!void {
        return self.vtable.exportLogsFn(self.ptr, log_records);
    }

    /// Shutdown the exporter
    pub fn shutdown(self: Self) anyerror!void {
        return self.vtable.shutdownFn(self.ptr);
    }
};
