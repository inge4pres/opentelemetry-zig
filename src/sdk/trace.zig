//! OpenTelemetry Tracing SDK.

pub const SpanProcessor = @import("trace/span_processor.zig").SpanProcessor;
pub const SimpleProcessor = @import("trace/span_processor.zig").SimpleProcessor;
pub const BatchingProcessor = @import("trace/span_processor.zig").BatchingProcessor;

pub const SpanExporter = @import("trace/span_exporter.zig").SpanExporter;

pub const TracerProvider = @import("trace/provider.zig").TracerProvider;
pub const Tracer = @import("trace/provider.zig").Tracer;
pub const IDGenerator = @import("trace/id_generator.zig").IDGenerator;
pub const RandomIDGenerator = @import("trace/id_generator.zig").RandomIDGenerator;

pub const StdOutExporter = @import("trace/exporter.zig").StdOutExporter;
pub const OTLPExporter = @import("trace/exporter.zig").OTLPExporter;

test {
    _ = @import("trace/exporter.zig");
    _ = @import("trace/id_generator.zig");
    _ = @import("trace/provider.zig");
    _ = @import("trace/span_exporter.zig");
    _ = @import("trace/span_processor.zig");
}
