const attributes = @import("../../attributes.zig");

pub const Event = struct {
    name: []const u8,
    attributes: []attributes.Attribute,
    time_uniX_nano: u64 = 0,
};
