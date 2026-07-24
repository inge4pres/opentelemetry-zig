const std = @import("std");

const trace = @import("../../../api/trace.zig");
const SpanExporter = @import("../span_exporter.zig").SpanExporter;
const Code = @import("../../../api/trace/code.zig").Code;
const InstrumentationScope = @import("../../../scope.zig").InstrumentationScope;

/// Serializable representation of a span for export purposes
const SerializableSpan = struct {
    trace_id: [16]u8,
    span_id: [8]u8,
    name: []const u8,
    kind: trace.SpanKind,
    start_time_unix_nano: u64,
    end_time_unix_nano: u64,
    status: ?struct {
        code: Code,
        description: []const u8,
    },

    pub fn fromSpan(span: trace.Span) SerializableSpan {
        return SerializableSpan{
            .trace_id = span.span_context.trace_id.value,
            .span_id = span.span_context.span_id.value,
            .name = span.name,
            .kind = span.kind,
            .start_time_unix_nano = span.start_time_unix_nano,
            .end_time_unix_nano = span.end_time_unix_nano,
            .status = if (span.status) |status| .{
                .code = status.code,
                .description = status.description,
            } else null,
        };
    }
};

/// WriterExporter outputs spans to the given writer.
const WriterExporter = struct {
    writer: *std.Io.Writer,

    const Self = @This();

    /// The writer must remain valid for the lifetime of the exporter.
    pub fn init(writer: *std.Io.Writer) Self {
        return Self{
            .writer = writer,
        };
    }

    pub fn exportSpans(ctx: *anyopaque, spans: []trace.Span) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Convert spans to serializable format
        var serializable_spans = std.ArrayList(SerializableSpan).empty;
        defer serializable_spans.deinit(std.heap.page_allocator);

        for (spans) |span| {
            try serializable_spans.append(std.heap.page_allocator, SerializableSpan.fromSpan(span));
        }

        try self.writer.print("{f}", .{std.json.fmt(serializable_spans.items, .{})});
        try self.writer.flush();
    }

    pub fn shutdown(_: *anyopaque) anyerror!void {}

    pub fn asSpanExporter(self: *Self) SpanExporter {
        return .{
            .ptr = self,
            .vtable = &.{
                .exportSpansFn = exportSpans,
                .shutdownFn = shutdown,
            },
        };
    }
};

/// StdoutExporter outputs spans into OS stdout.
/// ref: https://opentelemetry.io/docs/specs/otel/trace/sdk_exporters/stdout/
pub const StdoutExporter = WriterExporter;

/// InmemoryExporter exports spans to in-memory buffer.
/// it is designed for testing WriterExporter.
pub const InMemoryExporter = WriterExporter;

// Example showing how to use WriterExporter with an arbitrary writer.
test "exporters/trace WriterExporter" {
    var out_buf = std.ArrayList(u8).empty;
    {
        var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &out_buf);
        var inmemory_exporter = InMemoryExporter.init(&writer.writer);
        errdefer writer.deinit();
        var exporter = inmemory_exporter.asSpanExporter();

        // Create a test span
        const trace_id = trace.TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
        const span_id = trace.SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
        var trace_state = trace.TraceState.init(std.testing.allocator);
        defer trace_state.deinit();

        const span_context = trace.SpanContext.init(trace_id, span_id, trace.TraceFlags.default(), trace_state, false);
        const scope = InstrumentationScope{ .name = "test-lib", .version = "1.0.0" };
        var test_span = trace.Span.init(std.testing.allocator, span_context, "test-span", .Internal, scope);
        defer test_span.deinit();

        // Export the span
        var spans = [_]trace.Span{test_span};
        try exporter.exportSpans(spans[0..spans.len]);

        out_buf = writer.toArrayList();
    }
    defer out_buf.deinit(std.testing.allocator);

    // Verify output was written
    try std.testing.expect(out_buf.items.len > 0);
}

test StdoutExporter {
    // Note: We can't easily test actual stdout output, so we verify the type compiles
    // and can be instantiated correctly
    const io = std.testing.io;
    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stdout_exporter = StdoutExporter.init(&writer.interface);
    var exporter = stdout_exporter.asSpanExporter();

    // Create a test span to verify export works
    const trace_id = trace.TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const span_id = trace.SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    var trace_state = trace.TraceState.init(std.testing.allocator);
    defer trace_state.deinit();

    const span_context = trace.SpanContext.init(trace_id, span_id, trace.TraceFlags.default(), trace_state, false);
    const scope = InstrumentationScope{ .name = "test-lib", .version = "1.0.0" };
    var test_span = trace.Span.init(std.testing.allocator, span_context, "stdout-test", .Internal, scope);
    defer test_span.deinit();

    var spans = [_]trace.Span{test_span};
    // This will write to stdout - we just verify it doesn't error
    try exporter.exportSpans(spans[0..spans.len]);
    try exporter.shutdown();
}

test InMemoryExporter {
    var out_buf = std.ArrayList(u8).empty;
    {
        var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &out_buf);
        var inmemory_exporter = InMemoryExporter.init(&writer.writer);
        errdefer writer.deinit();
        var exporter = inmemory_exporter.asSpanExporter();

        // Create test spans with different properties
        const trace_id = trace.TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
        const span_id_1 = trace.SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
        const span_id_2 = trace.SpanID.init([8]u8{ 8, 7, 6, 5, 4, 3, 2, 1 });
        var trace_state = trace.TraceState.init(std.testing.allocator);
        defer trace_state.deinit();

        const scope = InstrumentationScope{ .name = "test-lib", .version = "1.0.0" };

        // First span - Internal kind
        const span_context_1 = trace.SpanContext.init(trace_id, span_id_1, trace.TraceFlags.default(), trace_state, false);
        var span_1 = trace.Span.init(std.testing.allocator, span_context_1, "span-internal", .Internal, scope);
        defer span_1.deinit();

        // Second span - Client kind
        const span_context_2 = trace.SpanContext.init(trace_id, span_id_2, trace.TraceFlags.default(), trace_state, false);
        var span_2 = trace.Span.init(std.testing.allocator, span_context_2, "span-client", .Client, scope);
        defer span_2.deinit();

        // Export spans
        var spans = [_]trace.Span{ span_1, span_2 };
        try exporter.exportSpans(spans[0..spans.len]);
        try exporter.shutdown();

        out_buf = writer.toArrayList();
    }
    defer out_buf.deinit(std.testing.allocator);

    // Verify JSON output contains expected span data
    try std.testing.expect(out_buf.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out_buf.items, "span-internal") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_buf.items, "span-client") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_buf.items, "Internal") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_buf.items, "Client") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_buf.items, "trace_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_buf.items, "span_id") != null);
}
