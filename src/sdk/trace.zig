pub const exporter = @import("trace/exporter.zig");
pub const span_processor = @import("trace/span_processor.zig");
pub const TracerProvider = @import("trace/provider.zig").TracerProvider;
pub const IDGenerator = @import("trace/id_generator.zig").IDGenerator;
pub const RandomIDGenerator = @import("trace/id_generator.zig").RandomIDGenerator;
pub const SimpleProcessor = @import("trace/span_processor.zig").SimpleProcessor;
pub const StdoutExporter = @import("trace/exporters/generic.zig").StdoutExporter;

test {
    _ = @import("trace/exporter.zig");
    _ = @import("trace/id_generator.zig");
    _ = @import("trace/provider.zig");
    _ = @import("trace/span_exporter.zig");
    _ = @import("trace/span_processor.zig");
}
