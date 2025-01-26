const std = @import("std");

pub const Tracer = @import("trace/tracer.zig").Tracer;
pub const TracerProvider = @import("trace/provider.zig").TracerProvider;
pub const TracerConfig = @import("trace/config.zig").TracerConfig;

pub const TraceID = struct {
    value: [16]u8,

    const Self = @This();

    pub fn init(value: [16]u8) Self {
        return .{
            .value = value,
        };
    }

    pub fn isValid(self: Self) bool {
        return Self.isValidValue(self.value);
    }

    pub fn isValidValue(value: [16]u8) bool {
        for (value) |item| {
            if (item != 0) {
                return true;
            }
        }

        return false;
    }
};

pub const SpanID = struct {
    value: [8]u8,

    const Self = @This();

    pub fn init(value: [8]u8) Self {
        return .{
            .value = value,
        };
    }

    pub fn isValid(self: Self) bool {
        return Self.isValidValue(self.value);
    }

    pub fn isValidValue(value: [8]u8) bool {
        for (value) |item| {
            if (item != 0) {
                return true;
            }
        }

        return false;
    }
};

test {
    _ = @import("trace/config.zig");
    _ = @import("trace/provider.zig");
    _ = @import("trace/tracer.zig");
}

test "TraceID isValid" {
    try std.testing.expect(TraceID.init([16]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).isValid());
    try std.testing.expect(!TraceID.init([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }).isValid());
}

test "SpanID isValid" {
    try std.testing.expect(SpanID.init([8]u8{
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    }).isValid());
    try std.testing.expect(!SpanID.init([8]u8{
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    }).isValid());
}
