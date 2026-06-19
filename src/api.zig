//! OpenTelemetry API for Zig.

// Export API modules
pub const baggage = @import("api/baggage.zig");
pub const context = @import("api/context.zig");
pub const trace = @import("api/trace.zig");
pub const metrics = @import("api/metrics.zig");
pub const logs = @import("api/logs.zig");

// Run API tests
test {
    _ = @import("api/baggage.zig");
    _ = @import("api/context.zig");
    _ = @import("api/trace.zig");
    _ = @import("api/metrics.zig");
    _ = @import("api/logs.zig");
}
