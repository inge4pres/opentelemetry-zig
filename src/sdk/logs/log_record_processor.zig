const std = @import("std");
const logs = @import("../../api/logs/logger_provider.zig");
const context = @import("../../api/context.zig");

/// LogRecordProcessor is an interface which allows hooks for LogRecord emitting.
/// see: https://opentelemetry.io/docs/specs/otel/logs/sdk/#logrecordprocessor
pub const LogRecordProcessor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    pub const VTable = struct {
        /// onEmit is called synchronously when a LogRecord is emitted.
        /// This method MUST NOT block and MUST NOT throw exceptions.
        /// The LogRecord can be modified, and mutations are visible to subsequent processors.
        onEmitFn: *const fn (ctx: *anyopaque, log_record: *logs.ReadWriteLogRecord, parent_context: context.Context) void,

        /// shutdown is called when the SDK is shut down.
        /// Should complete within a timeout and includes the effect of forceFlush.
        shutdownFn: *const fn (ctx: *anyopaque) anyerror!void,

        /// forceFlush ensures completion of pending LogRecord tasks.
        /// Should prioritize honoring the specified timeout.
        forceFlushFn: *const fn (ctx: *anyopaque) anyerror!void,
    };

    /// Called when a log record is emitted
    pub fn onEmit(self: Self, log_record: *logs.ReadWriteLogRecord, parent_context: context.Context) void {
        return self.vtable.onEmitFn(self.ptr, log_record, parent_context);
    }

    /// Shuts down the processor
    pub fn shutdown(self: Self) anyerror!void {
        return self.vtable.shutdownFn(self.ptr);
    }

    /// Forces a flush of any buffered log records
    pub fn forceFlush(self: Self) anyerror!void {
        return self.vtable.forceFlushFn(self.ptr);
    }
};