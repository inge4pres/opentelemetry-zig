const config = @import("config.zig");
const tracer = @import("tracer.zig");

/// TracerProvider is the interface that provides Tracers.
pub const TracerProvider = struct {
    /// tracer is the function signature that provides Tracer.
    tracer: *const fn (
        *TracerProvider,
        name: []const u8,
        config: ?config.TracerConfig,
    ) tracer.Tracer,
};
