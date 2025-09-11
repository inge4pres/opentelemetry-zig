// OpenTelemetry SDK implementation for Zig.

// Test SDK implementations
test {
    _ = @import("sdk/trace.zig");
    _ = @import("sdk/metrics.zig");
    // helpers
    _ = @import("attributes.zig");
    _ = @import("scope.zig");
    _ = @import("otlp.zig");
}

// Test API
test {
    _ = @import("api.zig");
}

// Export the entire API module for easy access
pub const api = @import("api.zig");

// SDK exports
pub const trace = @import("sdk/trace.zig");

// Direct exports for convenience
pub const MeterProvider = @import("api/metrics/meter.zig").MeterProvider;
pub const MetricReader = @import("sdk/metrics/reader.zig").MetricReader;
pub const MetricExporter = @import("sdk/metrics/exporter.zig").MetricExporter;
pub const InMemoryExporter = @import("sdk/metrics/exporters/in_memory.zig").InMemoryExporter;
pub const StdoutExporter = @import("sdk/metrics/exporters/stdout.zig").StdoutExporter;
pub const OTLPExporter = @import("sdk/metrics/exporters/otlp.zig").OTLPExporter;
pub const otlp = @import("otlp.zig");

// Attribute system exports
pub const Attribute = @import("attributes.zig").Attribute;
pub const AttributeValue = @import("attributes.zig").AttributeValue;
pub const Attributes = @import("attributes.zig").Attributes;

pub const Counter = @import("api/metrics/instrument.zig").Counter;
pub const UpDownCounter = @import("api/metrics/instrument.zig").Counter;
pub const Histogram = @import("api/metrics/instrument.zig").Histogram;
pub const Gauge = @import("api/metrics/instrument.zig").Gauge;
pub const View = @import("sdk/metrics/view.zig");
