const std = @import("std");

pub fn timeoutAfterMs(ms: u64) std.Io.Timeout {
    // NOTE: ms is u64, if this function is ever
    // widened to accept u128, the multiplication must be bounded.
    return .{
        .duration = .{
            .raw = .{ .nanoseconds = @as(i96, @intCast(ms)) * std.time.ns_per_ms },
            .clock = .awake,
        },
    };
}

fn PayloadOf(comptime Fn: type) type {
    const ret = @typeInfo(Fn).@"fn".return_type.?;
    return switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => ret,
    };
}

/// Calls `function` with `args`, propagates any error returned by "function",
/// or returns `error.Timeout` and cancels the execution of "function" takse more than `ms` milliseconds.
///
/// It works only when the `Io` implementation can multiplex fibers;
/// when it cannot, the call runs unbounded rather than failing (see the catch).
pub fn callTimeout(
    io: std.Io,
    ms: u64,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) !PayloadOf(@TypeOf(function)) {
    const Race = union(enum) {
        done: @typeInfo(@TypeOf(function)).@"fn".return_type.?,
        deadline: std.Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var race: std.Io.Select(Race) = .init(io, &results);

    race.concurrent(.done, function, args) catch return @call(.auto, function, args);
    defer race.cancelDiscard();

    // Nothing to race against: await the call as if no timeout was configured.
    race.concurrent(.deadline, std.Io.sleep, .{
        io,
        std.Io.Duration.fromMilliseconds(@intCast(ms)),
        .awake,
    }) catch {};

    return switch (try race.await()) {
        .done => |result| result,
        .deadline => error.Timeout,
    };
}
