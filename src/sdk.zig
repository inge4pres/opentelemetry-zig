// OpenTelemetry SDK implementation for Zig.

// Test SDK implementations
test {
    _ = @import("sdk/trace.zig");
    _ = @import("sdk/metrics.zig");
    // helpers
    _ = @import("pbutils.zig");
    _ = @import("attributes.zig");
    _ = @import("scope.zig");
    _ = @import("otlp.zig");
}

// Test API
test {
    _ = @import("api.zig");
}

pub const MeterProvider = @import("api/metrics/meter.zig").MeterProvider;
pub const MetricReader = @import("sdk/metrics/reader.zig").MetricReader;
pub const MetricExporter = @import("sdk/metrics/exporter.zig").MetricExporter;
pub const InMemoryExporter = @import("sdk/metrics/exporters/in_memory.zig").InMemoryExporter;

pub const Counter = @import("api/metrics/instrument.zig").Counter;
pub const UpDownCounter = @import("api/metrics/instrument.zig").Counter;
pub const Histogram = @import("api/metrics/instrument.zig").Histogram;
pub const Gauge = @import("api/metrics/instrument.zig").Gauge;

pub const Context = @import("api/context.zig").Context;
pub const ContextKey = @import("api/context.zig").ContextKey;
pub const Token = @import("api/context.zig").Token;
pub const DetachError = @import("api/context.zig").DetachError;
pub const createKey = @import("api/context.zig").createKey;
pub const Key = @import("api/context.zig").Key;
pub const getCurrentContext = @import("api/context.zig").getCurrentContext;
pub const attachContext = @import("api/context.zig").attachContext;
pub const detachContext = @import("api/context.zig").detachContext;
pub const cleanupContext = @import("api/context.zig").cleanup;
