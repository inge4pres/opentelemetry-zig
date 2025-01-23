pub const Tracer = @import("trace/tracer.zig").Tracer;
pub const TracerProvider = @import("trace/provider.zig").TracerProvider;
pub const TracerConfig = @import("trace/config.zig").TracerConfig;

test {
    _ = @import("trace/config.zig");
    _ = @import("trace/provider.zig");
    _ = @import("trace/tracer.zig");
}
