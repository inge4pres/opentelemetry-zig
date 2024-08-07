// OpenTelemetry SDK implementation for Zig.

// Test SDK implementations
test {
    _ = @import("metrics/test.zig");
    // helpers
    _ = @import("pbutils.zig");
}
