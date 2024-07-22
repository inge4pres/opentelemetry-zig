// OpenTelemetry SDK implementation for Zig.

test {
    // SDK implementations
    _ = @import("metrics_test.zig");
    // helpers
    _ = @import("pb_utils.zig");
    _ = @import("spec.zig");
}
