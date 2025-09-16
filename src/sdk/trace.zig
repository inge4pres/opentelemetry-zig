pub const SpanProcessor = @import("trace/span_processor.zig").SpanProcessor;
pub const SimpleProcessor = @import("trace/span_processor.zig").SimpleProcessor;
pub const BatchingProcessor = @import("trace/span_processor.zig").BatchingProcessor;

pub const SpanExporter = @import("trace/span_exporter.zig").SpanExporter;

pub const SDKTracerProvider = @import("trace/provider.zig").TracerProvider;
pub const SDKTracer = @import("trace/provider.zig").Tracer;
pub const IDGenerator = @import("trace/id_generator.zig").IDGenerator;
pub const RandomIDGenerator = @import("trace/id_generator.zig").RandomIDGenerator;

pub const StdOutExporter = @import("trace/exporter.zig").StdOutExporter;

test {
    _ = @import("trace/exporter.zig");
    _ = @import("trace/id_generator.zig");
    _ = @import("trace/provider.zig");
    _ = @import("trace/span_exporter.zig");
    _ = @import("trace/span_processor.zig");
}
