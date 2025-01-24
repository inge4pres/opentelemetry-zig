test {
    _ = @import("metrics/instrument.zig");
    _ = @import("metrics/measurement.zig");
    _ = @import("metrics/meter.zig");
    _ = @import("metrics/spec.zig");
}

pub const MeterProvider = @import("metrics/meter.zig").MeterProvider;
