const std = @import("std");

pub const Tracer = @import("trace/tracer.zig").Tracer;
pub const TracerProvider = @import("trace/provider.zig").TracerProvider;
pub const TracerConfig = @import("trace/config.zig").TracerConfig;

const span = @import("trace/span.zig");
pub const Span = span.Span;
pub const SpanKind = span.SpanKind;
pub const Status = span.Status;
pub const Event = @import("trace/event.zig").Event;
pub const Code = @import("trace/code.zig").Code;
pub const Link = @import("trace/link.zig").Link;

test {
    _ = @import("trace/code.zig");
    _ = @import("trace/config.zig");
    _ = @import("trace/event.zig");
    _ = @import("trace/link.zig");
    _ = @import("trace/provider.zig");
    _ = @import("trace/span.zig");
    _ = @import("trace/tracer.zig");
}

pub const TraceID = struct {
    value: [16]u8,

    const Self = @This();

    pub fn init(value: [16]u8) Self {
        return .{
            .value = value,
        };
    }

    pub fn zero() Self {
        return init([16]u8{
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        });
    }

    pub fn isValid(self: Self) bool {
        for (self.value) |item| {
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

    pub fn zero() Self {
        return init([8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    }

    pub fn isValid(self: Self) bool {
        for (self.value) |item| {
            if (item != 0) {
                return true;
            }
        }

        return false;
    }
};

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
