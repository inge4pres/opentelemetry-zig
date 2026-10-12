//! OpenTelemetry W3C Trace Context Propagator.
//!
//! This module implements the W3C Trace Context specification for propagating
//! SpanContext across process boundaries via the `traceparent` and `tracestate`
//! HTTP headers.
//!
//! `traceparent` format: `version-trace_id-parent_id-trace_flags`
//! - Dash-delimited, lowercase hex-encoded fields
//! - `version`: 2 hex chars (currently only `00` is fully specified, `ff` is invalid)
//! - `trace_id`: 32 hex chars (16 bytes), must not be all zeros
//! - `parent_id`: 16 hex chars (8 bytes), must not be all zeros
//! - `trace_flags`: 2 hex chars (1 byte), e.g. bit 0 is the sampled flag
//! - Fixed total length of 55 characters for version `00`
//!
//! `tracestate` format: comma-separated `key=value` vendor entries
//! - Up to 32 list-members
//! - Entries are propagated in the order they appear in the TraceState
//! - An invalid `tracestate` is discarded as a whole, without affecting `traceparent`
//!
//! Example usage:
//! ```zig
//! const api = @import("opentelemetry-sdk").api;
//! const propagator = api.trace.propagator;
//!
//! // Outgoing request: the header values are allocated, the caller frees them.
//! var headers = std.StringHashMap([]const u8).init(allocator);
//! try propagator.inject(allocator, span_context, &headers, api.propagation.HttpSetter);
//!
//! // Incoming request: returns null when there is no valid `traceparent`.
//! if (try propagator.extract(allocator, &headers, api.propagation.HttpGetter)) |remote| {
//!     var trace_state = remote.trace_state;
//!     defer trace_state.deinit();
//!     // ...
//! }
//! ```
//!
//! From W3C Trace Context specification: https://www.w3.org/TR/trace-context/
//!

const std = @import("std");
const SpanContext = @import("span.zig").SpanContext;
const TraceState = @import("span.zig").TraceState;
const TraceFlags = @import("trace_flags.zig").TraceFlags;
const TraceID = @import("../trace.zig").TraceID;
const SpanID = @import("../trace.zig").SpanID;
const propagation = @import("../propagation.zig");

/// W3C traceparent header name
pub const traceparent_header = "traceparent";

/// W3C tracestate header name
pub const tracestate_header = "tracestate";

/// Version of the traceparent format written by `inject`
const supported_version: u8 = 0x00;

/// Version reserved by the spec as invalid
const invalid_version: u8 = 0xff;

/// Length of a version `00` traceparent value
const traceparent_length = 55;

/// Maximum number of list-members in a tracestate header
const max_tracestate_members = 32;

/// Trace flags defined by the spec; unknown bits are dropped on extract and zeroed on inject
const known_trace_flags: u8 = TraceFlags.SAMPLED_FLAG | TraceFlags.RANDOM_FLAG;

/// Optional whitespace allowed around header values and tracestate list-members
const optional_whitespace = " \t";

/// Inject a SpanContext into a carrier as `traceparent` and `tracestate`.
///
/// Nothing is injected for an invalid SpanContext. `tracestate` is only
/// injected when the TraceState has entries.
///
/// The header values are allocated with `allocator` and handed to the carrier;
/// the owner of the carrier is responsible for freeing them.
pub fn inject(
    allocator: std.mem.Allocator,
    span_context: SpanContext,
    carrier: anytype,
    setter: propagation.TextMapSetter(@TypeOf(carrier.*)),
) !void {
    if (!span_context.isValid()) return;

    const traceparent = try formatTraceparent(allocator, span_context);
    setter.set(carrier, traceparent_header, traceparent) catch |err| {
        allocator.free(traceparent);
        return err;
    };

    const tracestate = try formatTracestate(allocator, span_context.getTraceState()) orelse return;
    setter.set(carrier, tracestate_header, tracestate) catch |err| {
        allocator.free(tracestate);
        return err;
    };
}

/// Extract a remote SpanContext from a carrier's `traceparent` and `tracestate`.
///
/// Returns null when `traceparent` is missing or invalid. Errors are only
/// returned for allocation failures; malformed headers never error.
///
/// The returned TraceState owns a copy of the carrier's `tracestate`, so the
/// carrier can be released right away. Release the TraceState with
/// `trace_state.deinit()`.
pub fn extract(
    allocator: std.mem.Allocator,
    carrier: anytype,
    getter: propagation.TextMapGetter(@TypeOf(carrier.*)),
) !?SpanContext {
    const traceparent = getter.get(carrier, traceparent_header) orelse return null;
    const parsed = parseTraceparent(traceparent) orelse return null;

    const trace_state = if (getter.get(carrier, tracestate_header)) |tracestate|
        try parseTracestate(allocator, tracestate)
    else
        TraceState.init(allocator);

    return SpanContext.init(parsed.trace_id, parsed.span_id, parsed.trace_flags, trace_state, true);
}

/// Fields read and written by this propagator
pub fn fields() []const []const u8 {
    return &.{ traceparent_header, tracestate_header };
}

fn formatTraceparent(allocator: std.mem.Allocator, span_context: SpanContext) ![]u8 {
    var trace_id_buf: [32]u8 = undefined;
    var span_id_buf: [16]u8 = undefined;

    return std.fmt.allocPrint(allocator, "{x:0>2}-{s}-{s}-{x:0>2}", .{
        supported_version,
        span_context.getTraceId().toHex(&trace_id_buf),
        span_context.getSpanId().toHex(&span_id_buf),
        span_context.getTraceFlags().value & known_trace_flags,
    });
}

/// Returns null when the TraceState has no entries
fn formatTracestate(allocator: std.mem.Allocator, trace_state: TraceState) !?[]u8 {
    if (trace_state.entries.count() == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (trace_state.entries.keys(), trace_state.entries.values(), 0..) |key, value, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, key);
        try buf.append(allocator, '=');
        try buf.appendSlice(allocator, value);
    }

    return try buf.toOwnedSlice(allocator);
}

const Traceparent = struct {
    trace_id: TraceID,
    span_id: SpanID,
    trace_flags: TraceFlags,
};

/// Returns null when the value is not a valid traceparent
fn parseTraceparent(header: []const u8) ?Traceparent {
    const value = std.mem.trim(u8, header, optional_whitespace);
    if (value.len < traceparent_length) return null;

    var version: [1]u8 = undefined;
    if (!parseLowerHex(&version, value[0..2])) return null;
    if (version[0] == invalid_version) return null;

    // Version 00 has a fixed length. Future versions may append fields,
    // which must be separated by a dash and are ignored here.
    if (version[0] == supported_version) {
        if (value.len != traceparent_length) return null;
    } else if (value.len > traceparent_length and value[traceparent_length] != '-') {
        return null;
    }

    if (value[2] != '-' or value[35] != '-' or value[52] != '-') return null;

    var trace_id: [16]u8 = undefined;
    var span_id: [8]u8 = undefined;
    var trace_flags: [1]u8 = undefined;
    if (!parseLowerHex(&trace_id, value[3..35])) return null;
    if (!parseLowerHex(&span_id, value[36..52])) return null;
    if (!parseLowerHex(&trace_flags, value[53..55])) return null;

    const result = Traceparent{
        .trace_id = TraceID.init(trace_id),
        .span_id = SpanID.init(span_id),
        .trace_flags = TraceFlags.init(trace_flags[0] & known_trace_flags),
    };
    if (!result.trace_id.isValid() or !result.span_id.isValid()) return null;

    return result;
}

/// Decode lowercase hex into `out`. Returns false on any other character.
fn parseLowerHex(out: []u8, hex: []const u8) bool {
    std.debug.assert(hex.len == out.len * 2);
    for (hex) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    _ = std.fmt.hexToBytes(out, hex) catch return false;
    return true;
}

/// Parse a tracestate header into a TraceState that owns its strings.
/// An invalid header yields an empty TraceState.
fn parseTracestate(allocator: std.mem.Allocator, header: []const u8) !TraceState {
    // Entries borrow from the header until they are cloned below
    var borrowed = TraceState.init(allocator);
    defer borrowed.deinit();

    if (!try appendTracestateMembers(&borrowed, header)) {
        return TraceState.init(allocator);
    }
    return borrowed.clone(allocator);
}

/// Returns false when the header is not a valid tracestate.
/// Uses `append` so list-members keep their order on the wire; `insert` would
/// move each one to the front and reverse the header.
fn appendTracestateMembers(trace_state: *TraceState, header: []const u8) !bool {
    var member_count: usize = 0;
    var members = std.mem.splitScalar(u8, header, ',');
    while (members.next()) |raw_member| {
        // Empty list-members are allowed and skipped
        const member = std.mem.trim(u8, raw_member, optional_whitespace);
        if (member.len == 0) continue;

        member_count += 1;
        if (member_count > max_tracestate_members) return false;

        const separator = std.mem.indexOfScalar(u8, member, '=') orelse return false;
        const key = member[0..separator];
        const value = member[separator + 1 ..];
        // W3C allows one entry per key; a duplicate invalidates the header
        if (trace_state.get(key) != null) return false;

        trace_state.append(key, value) catch |err| switch (err) {
            error.InvalidTraceStateKey, error.InvalidTraceStateValue => return false,
            else => |e| return e,
        };
    }
    return true;
}

// Tests

const Headers = std.StringHashMap([]const u8);

fn freeInjectedHeaders(headers: *Headers) void {
    var it = headers.valueIterator();
    while (it.next()) |value| headers.allocator.free(value.*);
    headers.deinit();
}

fn testSpanContext(trace_state: TraceState, trace_flags: TraceFlags) !SpanContext {
    return SpanContext.init(
        try TraceID.fromHex("0af7651916cd43dd8448eb211c80319c"),
        try SpanID.fromHex("b7ad6b7169203331"),
        trace_flags,
        trace_state,
        false,
    );
}

fn extractFromTraceparent(traceparent: []const u8) !?SpanContext {
    var headers = Headers.init(std.testing.allocator);
    defer headers.deinit();
    try headers.put(traceparent_header, traceparent);

    return extract(std.testing.allocator, &headers, propagation.HttpGetter);
}

test "inject writes traceparent" {
    const allocator = std.testing.allocator;

    var trace_state = TraceState.init(allocator);
    defer trace_state.deinit();

    var headers = Headers.init(allocator);
    defer freeInjectedHeaders(&headers);

    try inject(allocator, try testSpanContext(trace_state, TraceFlags.sampled()), &headers, propagation.HttpSetter);

    try std.testing.expectEqualStrings(
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        headers.get(traceparent_header).?,
    );
    // Empty TraceState is not injected
    try std.testing.expect(headers.get(tracestate_header) == null);
}

test "inject writes unsampled flags" {
    const allocator = std.testing.allocator;

    var trace_state = TraceState.init(allocator);
    defer trace_state.deinit();

    var headers = Headers.init(allocator);
    defer freeInjectedHeaders(&headers);

    try inject(allocator, try testSpanContext(trace_state, TraceFlags.default()), &headers, propagation.HttpSetter);

    try std.testing.expectEqualStrings(
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00",
        headers.get(traceparent_header).?,
    );
}

test "inject zeroes unknown trace flags" {
    const allocator = std.testing.allocator;

    var trace_state = TraceState.init(allocator);
    defer trace_state.deinit();

    var headers = Headers.init(allocator);
    defer freeInjectedHeaders(&headers);

    try inject(allocator, try testSpanContext(trace_state, TraceFlags.init(0xff)), &headers, propagation.HttpSetter);

    try std.testing.expectEqualStrings(
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-03",
        headers.get(traceparent_header).?,
    );
}

test "inject writes tracestate in order" {
    const allocator = std.testing.allocator;

    var empty = TraceState.init(allocator);
    defer empty.deinit();
    var one = try empty.insert(allocator, "rojo", "00f067aa0ba902b7");
    defer one.deinit();
    var two = try one.insert(allocator, "congo", "t61rcWkgMzE");
    defer two.deinit();

    var headers = Headers.init(allocator);
    defer freeInjectedHeaders(&headers);

    try inject(allocator, try testSpanContext(two, TraceFlags.sampled()), &headers, propagation.HttpSetter);

    // The most recently inserted entry is the left-most list-member
    try std.testing.expectEqualStrings("congo=t61rcWkgMzE,rojo=00f067aa0ba902b7", headers.get(tracestate_header).?);
}

test "extract then inject keeps tracestate order" {
    const allocator = std.testing.allocator;
    const tracestate = "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE,blue=x";

    var incoming = Headers.init(allocator);
    defer incoming.deinit();
    try incoming.put(traceparent_header, "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
    try incoming.put(tracestate_header, tracestate);

    var span_context = (try extract(allocator, &incoming, propagation.HttpGetter)).?;
    defer span_context.trace_state.deinit();

    var outgoing = Headers.init(allocator);
    defer freeInjectedHeaders(&outgoing);
    try inject(allocator, span_context, &outgoing, propagation.HttpSetter);

    try std.testing.expectEqualStrings(tracestate, outgoing.get(tracestate_header).?);
}

test "inject skips invalid span context" {
    const allocator = std.testing.allocator;

    var trace_state = TraceState.init(allocator);
    defer trace_state.deinit();

    var headers = Headers.init(allocator);
    defer freeInjectedHeaders(&headers);

    const invalid = SpanContext.init(TraceID.zero(), SpanID.zero(), TraceFlags.default(), trace_state, false);
    try inject(allocator, invalid, &headers, propagation.HttpSetter);

    try std.testing.expectEqual(@as(u32, 0), headers.count());
}

test "extract valid traceparent" {
    var span_context = (try extractFromTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")).?;
    defer span_context.trace_state.deinit();

    var trace_id_buf: [32]u8 = undefined;
    var span_id_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0af7651916cd43dd8448eb211c80319c", span_context.trace_id.toHex(&trace_id_buf));
    try std.testing.expectEqualStrings("b7ad6b7169203331", span_context.span_id.toHex(&span_id_buf));
    try std.testing.expect(span_context.trace_flags.isSampled());
    try std.testing.expect(span_context.isRemote());
    try std.testing.expect(span_context.isValid());
    try std.testing.expectEqual(@as(usize, 0), span_context.trace_state.entries.count());
}

test "extract without traceparent returns null" {
    var headers = Headers.init(std.testing.allocator);
    defer headers.deinit();
    try headers.put(tracestate_header, "rojo=00f067aa0ba902b7");

    try std.testing.expect(try extract(std.testing.allocator, &headers, propagation.HttpGetter) == null);
}

test "extract rejects invalid traceparent" {
    const invalid = [_][]const u8{
        "",
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331", // missing flags
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-0", // too short
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-", // version 00 too long
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-extra",
        "ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", // forbidden version
        "00-00000000000000000000000000000000-b7ad6b7169203331-01", // zero trace id
        "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01", // zero span id
        "00-0AF7651916CD43DD8448EB211C80319C-b7ad6b7169203331-01", // uppercase trace id
        "00-0af7651916cd43dd8448eb211c80319c-B7AD6B7169203331-01", // uppercase span id
        "0A-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", // uppercase version
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-0X", // non-hex flags
        "00-+af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", // sign character
        "00_0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", // wrong delimiter
        "00-0af7651916cd43dd8448eb211c80319c_b7ad6b7169203331-01",
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331_01",
        "cc-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01extra", // future version, no dash
    };

    for (invalid) |traceparent| {
        if (try extractFromTraceparent(traceparent)) |span_context| {
            var trace_state = span_context.trace_state;
            trace_state.deinit();
            std.debug.print("accepted invalid traceparent: '{s}'\n", .{traceparent});
            return error.TestUnexpectedResult;
        }
    }
}

test "extract accepts future versions with extra fields" {
    var span_context = (try extractFromTraceparent("cc-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-what-the-future-holds")).?;
    defer span_context.trace_state.deinit();

    try std.testing.expect(span_context.trace_flags.isSampled());
    try std.testing.expect(span_context.isValid());
}

test "extract trims optional whitespace" {
    var span_context = (try extractFromTraceparent(" \t00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01 ")).?;
    defer span_context.trace_state.deinit();

    try std.testing.expect(span_context.isValid());
}

test "extract drops unknown trace flags" {
    var span_context = (try extractFromTraceparent("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-ff")).?;
    defer span_context.trace_state.deinit();

    try std.testing.expectEqual(known_trace_flags, span_context.trace_flags.value);
}

test "extract parses tracestate" {
    const allocator = std.testing.allocator;

    var headers = Headers.init(allocator);
    defer headers.deinit();
    try headers.put(traceparent_header, "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
    try headers.put(tracestate_header, "rojo=00f067aa0ba902b7, ,\tcongo=t61rcWkgMzE , tenant@vendor=x");

    var span_context = (try extract(allocator, &headers, propagation.HttpGetter)).?;
    defer span_context.trace_state.deinit();

    const trace_state = span_context.trace_state;
    try std.testing.expectEqual(@as(usize, 3), trace_state.entries.count());
    try std.testing.expectEqualStrings("rojo", trace_state.entries.keys()[0]);
    try std.testing.expectEqualStrings("congo", trace_state.entries.keys()[1]);
    try std.testing.expectEqualStrings("00f067aa0ba902b7", trace_state.get("rojo").?);
    try std.testing.expectEqualStrings("t61rcWkgMzE", trace_state.get("congo").?);
    try std.testing.expectEqualStrings("x", trace_state.get("tenant@vendor").?);
}

test "extracted tracestate outlives the carrier" {
    const allocator = std.testing.allocator;

    const tracestate = try allocator.dupe(u8, "rojo=00f067aa0ba902b7");

    var headers = Headers.init(allocator);
    defer headers.deinit();
    try headers.put(traceparent_header, "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
    try headers.put(tracestate_header, tracestate);

    var span_context = (try extract(allocator, &headers, propagation.HttpGetter)).?;
    defer span_context.trace_state.deinit();

    allocator.free(tracestate);

    try std.testing.expectEqualStrings("00f067aa0ba902b7", span_context.trace_state.get("rojo").?);
}

test "extract discards invalid tracestate but keeps traceparent" {
    const allocator = std.testing.allocator;

    const too_many = "a0=v,a1=v,a2=v,a3=v,a4=v,a5=v,a6=v,a7=v,a8=v,a9=v," ++
        "b0=v,b1=v,b2=v,b3=v,b4=v,b5=v,b6=v,b7=v,b8=v,b9=v," ++
        "c0=v,c1=v,c2=v,c3=v,c4=v,c5=v,c6=v,c7=v,c8=v,c9=v," ++
        "d0=v,d1=v,d2=v";

    const invalid = [_][]const u8{
        "rojo=00f067aa0ba902b7,Congo=t61rcWkgMzE", // uppercase key
        "rojo=00f067aa0ba902b7,congo", // missing '='
        "rojo=00f067aa0ba902b7,congo=", // empty value
        "rojo=00f067aa0ba902b7,congo=a=b", // '=' in value
        "rojo=1,rojo=2", // duplicate key
        too_many, // 33 list-members
    };

    for (invalid) |tracestate| {
        var headers = Headers.init(allocator);
        defer headers.deinit();
        try headers.put(traceparent_header, "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
        try headers.put(tracestate_header, tracestate);

        var span_context = (try extract(allocator, &headers, propagation.HttpGetter)).?;
        defer span_context.trace_state.deinit();

        try std.testing.expect(span_context.isValid());
        std.testing.expectEqual(@as(usize, 0), span_context.trace_state.entries.count()) catch |err| {
            std.debug.print("accepted invalid tracestate: '{s}'\n", .{tracestate});
            return err;
        };
    }
}

test "extract accepts 32 tracestate members" {
    const allocator = std.testing.allocator;

    const max_members = "a0=v,a1=v,a2=v,a3=v,a4=v,a5=v,a6=v,a7=v,a8=v,a9=v," ++
        "b0=v,b1=v,b2=v,b3=v,b4=v,b5=v,b6=v,b7=v,b8=v,b9=v," ++
        "c0=v,c1=v,c2=v,c3=v,c4=v,c5=v,c6=v,c7=v,c8=v,c9=v," ++
        "d0=v,d1=v";

    var headers = Headers.init(allocator);
    defer headers.deinit();
    try headers.put(traceparent_header, "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
    try headers.put(tracestate_header, max_members);

    var span_context = (try extract(allocator, &headers, propagation.HttpGetter)).?;
    defer span_context.trace_state.deinit();

    try std.testing.expectEqual(@as(usize, max_tracestate_members), span_context.trace_state.entries.count());
}

test "inject and extract round trip" {
    const allocator = std.testing.allocator;

    var empty = TraceState.init(allocator);
    defer empty.deinit();
    var trace_state = try empty.insert(allocator, "rojo", "00f067aa0ba902b7");
    defer trace_state.deinit();

    const original = try testSpanContext(trace_state, TraceFlags.sampled());

    var headers = Headers.init(allocator);
    defer freeInjectedHeaders(&headers);
    try inject(allocator, original, &headers, propagation.HttpSetter);

    var extracted = (try extract(allocator, &headers, propagation.HttpGetter)).?;
    defer extracted.trace_state.deinit();

    try std.testing.expectEqualSlices(u8, &original.trace_id.value, &extracted.trace_id.value);
    try std.testing.expectEqualSlices(u8, &original.span_id.value, &extracted.span_id.value);
    try std.testing.expectEqual(original.trace_flags.value, extracted.trace_flags.value);
    try std.testing.expectEqualStrings("00f067aa0ba902b7", extracted.trace_state.get("rojo").?);
    try std.testing.expect(extracted.isRemote());
}
