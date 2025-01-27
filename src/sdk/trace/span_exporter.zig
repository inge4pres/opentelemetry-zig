const trace = @import("../../api/trace.zig");

/// SpanExporter is the interface that provides an
pub const SpanExporter = struct {
    // std.mem.Allocator's style
    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    /// VTable defines the methods that the SpanExporter's instance must implement.
    pub const VTable = struct {
        /// exportSpans is the method that export a batch of spans.
        /// NOTE: In other languages, the span types is ReadOnlySpan for improving stability.
        /// but it is not defined in the OpenTelemetry specification, so for now we don't use it.
        exportSpansFn: *const fn (
            ctx: *anyopaque,
            spans: []trace.Span,
        ) anyerror!void,

        shutdownFn: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn exportSpans(
        self: Self,
        spans: []trace.Span,
    ) anyerror!void {
        return self.vtable.exportSpansFn(self.ptr, spans);
    }
};
