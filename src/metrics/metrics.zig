test {
    _ = @import("meter.zig");
    _ = @import("instrument.zig");
    _ = @import("spec.zig");
    _ = @import("attributes.zig");
    _ = @import("measurement.zig");

}

pub const MeterProvider = @import("meter.zig").MeterProvider;
