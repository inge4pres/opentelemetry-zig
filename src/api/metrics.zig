/// MeterProvider is the registry to create meters and record measurements.
pub const MeterProvider = @import("metrics/meter.zig").MeterProvider;

test {
    _ = @import("metrics/instrument.zig");
    _ = @import("metrics/measurement.zig");
    _ = @import("metrics/meter.zig");
    _ = @import("metrics/spec.zig");
}
