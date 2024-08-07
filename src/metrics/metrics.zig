test {
    _ = @import("meter.zig");
    _ = @import("instrument.zig");
    _ = @import("spec.zig");
}

pub const MeterProvider = @import("meter.zig").MeterProvider;
