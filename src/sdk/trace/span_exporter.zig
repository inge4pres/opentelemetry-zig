const trace = @import("../../api/trace.zig");

/// SpanExporter defines the interface that protocol-specific exporters must implement
pub const SpanExporter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    /// VTable defines the methods that the SpanExporter's instance must implement.
    pub const VTable = struct {
        /// exportSpans is the method that exports a batch of spans.
        /// NOTE: In other languages, the span types is ReadOnlySpan for improving stability.
        /// but it is not defined in the OpenTelemetry specification, so for now we don't use it.
        exportSpansFn: *const fn (
            ctx: *anyopaque,
            spans: []trace.Span,
        ) anyerror!void,

        /// shutdown shuts down the exporter
        shutdownFn: *const fn (ctx: *anyopaque) anyerror!void,
    };

    /// Export a batch of spans
    pub fn exportSpans(
        self: Self,
        spans: []trace.Span,
    ) anyerror!void {
        return self.vtable.exportSpansFn(self.ptr, spans);
    }

    /// Shutdown the exporter
    pub fn shutdown(self: Self) anyerror!void {
        return self.vtable.shutdownFn(self.ptr);
    }
};
