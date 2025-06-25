// Run API tests
test {
    _ = @import("api/context.zig");
    _ = @import("api/trace.zig");
    _ = @import("api/metrics.zig");
    _ = @import("api/logs.zig");
}
