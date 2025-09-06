const attributes = @import("../../attributes.zig");

/// Event represents a timestamped event in a Span
pub const Event = struct {
    name: []const u8,
    attributes: []attributes.Attribute,
    timestamp_unix_nano: u64 = 0,

    const Self = @This();

    pub fn init(name: []const u8, timestamp: u64, attrs: []attributes.Attribute) Self {
        return Self{
            .name = name,
            .timestamp_unix_nano = timestamp,
            .attributes = attrs,
        };
    }
};
