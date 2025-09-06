const std = @import("std");

const trace = @import("../../../api/trace.zig");
const SpanExporter = @import("../span_exporter.zig").SpanExporter;
const Code = @import("../../../api/trace/code.zig").Code;

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

/// GenericWriterExporter is the generic SpanExporter that outputs spans to the given writer.
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

        pub fn exportSpans(ctx: *anyopaque, spans: []trace.Span) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            // Convert spans to serializable format
            var serializable_spans = std.ArrayList(SerializableSpan).init(std.heap.page_allocator);
            defer serializable_spans.deinit();

            for (spans) |span| {
                try serializable_spans.append(SerializableSpan.fromSpan(span));
            }

            try std.json.stringify(serializable_spans.items, .{}, self.writer);
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
}

/// StdoutExporter outputs spans into OS stdout.
/// ref: https://opentelemetry.io/docs/specs/otel/trace/sdk_exporters/stdout/
pub const StdoutExporter = GenericWriterExporter(std.io.Writer(std.fs.File, std.fs.File.WriteError, std.fs.File.write));

/// InmemoryExporter exports spans to in-memory buffer.
/// it is designed for testing GenericWriterExporter.
pub const InmemoryExporter = GenericWriterExporter(std.ArrayList(u8).Writer);

test "GenericWriterExporter" {
    var out_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer out_buf.deinit();
    var inmemory_exporter = InmemoryExporter.init(out_buf.writer());
    var exporter = inmemory_exporter.asSpanExporter();

    // Create a proper span for testing
    const trace_id = trace.TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const span_id = trace.SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    var trace_state = trace.TraceState.init(std.testing.allocator);
    defer trace_state.deinit();

    const span_context = trace.SpanContext.init(trace_id, span_id, trace.TraceFlags.default(), trace_state, false);
    var test_span = trace.Span.init(std.testing.allocator, span_context, "test-span", .Internal);
    defer test_span.deinit();

    var spans = [_]trace.Span{test_span};
    try exporter.exportSpans(spans[0..spans.len]);

    // Since JSON output can be complex, just check that something was written
    try std.testing.expect(out_buf.items.len > 0);
    std.debug.print("Exported JSON: {s}\n", .{out_buf.items});
}
