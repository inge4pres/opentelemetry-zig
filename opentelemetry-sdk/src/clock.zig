const std = @import("std");

fn realtimeTimespec() std.c.timespec {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts;
}

/// Wall-clock timestamp in seconds since UNIX epoch.
/// Uses CLOCK_REALTIME. Suitable for absolute span timestamps per OTel spec.
/// NOTE: Subject to NTP adjustments and wall-clock jumps.
pub fn timestamp() i64 {
    const ts = realtimeTimespec();
    return @intCast(ts.sec);
}

/// Wall-clock timestamp in milliseconds since UNIX epoch.
/// Uses CLOCK_REALTIME. Suitable for absolute span timestamps per OTel spec.
/// NOTE: Subject to NTP adjustments and wall-clock jumps.
pub fn milliTimestamp() i64 {
    const ts = realtimeTimespec();
    return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

/// Wall-clock timestamp in nanoseconds since UNIX epoch.
/// Uses CLOCK_REALTIME. Suitable for absolute span start/end times per OTel spec.
/// NOTE: Subject to NTP adjustments and wall-clock jumps.
pub fn nanoTimestamp() i128 {
    const ts = realtimeTimespec();
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn monotonicTimespec() std.c.timespec {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return ts;
}

/// Monotonic nanoseconds suitable for elapsed-time measurements.
/// Does not suffer from wall-clock adjustments (NTP, DST, etc.).
pub fn monotonicNs() u64 {
    const ts = monotonicTimespec();
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn sleep(ns: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

pub fn timeoutAfterNs(ns: u64) std.Io.Timeout {
    return .{
        .duration = .{
            .raw = .{ .nanoseconds = @intCast(ns) },
            .clock = .awake,
        },
    };
}

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

pub fn waitTimeout(io: std.Io, event: *std.Io.Event, ns: u64) (error{Timeout} || std.Io.Cancelable)!void {
    return event.waitTimeout(io, timeoutAfterNs(ns));
}

fn PayloadOf(comptime Fn: type) type {
    const ret = @typeInfo(Fn).@"fn".return_type.?;
    return switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => ret,
    };
}

/// Calls `function` with `args`, returning `error.Timeout` and canceling it if
/// it has not finished after `ms` milliseconds.
///
/// It works only when the `Io` implementation can multiplex fibers; 
/// when it cannot, the call runs unbounded rather than failing (see the catch)
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
