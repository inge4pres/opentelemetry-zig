test {
    _ = @import("attributes.zig");
    _ = @import("exporter.zig");
    _ = @import("instrument.zig");
    _ = @import("measurement.zig");
    _ = @import("meter.zig");
    _ = @import("reader.zig");
    _ = @import("spec.zig");
    _ = @import("view.zig");
}

pub const MeterProvider = @import("meter.zig").MeterProvider;
