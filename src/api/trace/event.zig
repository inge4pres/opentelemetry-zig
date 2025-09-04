const attributes = @import("../../attributes.zig");

pub const Event = struct {
    name: []const u8,
    attributes: []attributes.Attribute,
    timestamp_unix_nano: u64 = 0,

    pub fn init(name: []const u8, timestamp: u64, attrs: []attributes.Attribute) Event {
        return Event{
            .name = name,
            .timestamp_unix_nano = timestamp,
            .attributes = attrs,
        };
    }
};
