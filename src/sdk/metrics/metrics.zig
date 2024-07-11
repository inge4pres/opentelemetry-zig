pub const Unit = enum {
    Count,
    Bytes,
    KiB,
    MiB,
    GiB,
};

pub const Metric = struct {
    name: []const u8,
    description: []const u8,
    unit: Unit,
    value: f64,
};