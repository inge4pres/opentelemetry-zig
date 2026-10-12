//! Shared carrier interfaces for text map propagators.
//!
//! Propagators (W3C Trace Context, W3C Baggage, ...) read from and write to
//! carriers through `TextMapGetter` and `TextMapSetter`, so the same propagator
//! works with HTTP headers, environment variables, or any other string map.

const std = @import("std");

/// Generic interface for getting values from a carrier.
///
/// Implementations must provide methods to retrieve propagation data from
/// carriers like HTTP headers or environment variables.
pub fn TextMapGetter(comptime Carrier: type) type {
    return struct {
        /// Get a single value for a given key.
        /// Returns null if the key doesn't exist.
        /// Must be case-insensitive for HTTP carriers.
        getFn: *const fn (carrier: *const Carrier, key: []const u8) ?[]const u8,

        /// Get all keys available in the carrier.
        /// Returns a slice of key names.
        keysFn: *const fn (carrier: *const Carrier) []const []const u8,

        const Self = @This();

        pub fn get(self: Self, carrier: *const Carrier, key: []const u8) ?[]const u8 {
            return self.getFn(carrier, key);
        }

        pub fn keys(self: Self, carrier: *const Carrier) []const []const u8 {
            return self.keysFn(carrier);
        }
    };
}

/// Generic interface for setting values in a carrier.
///
/// Implementations must provide a method to inject propagation data into
/// carriers like HTTP headers or environment variables.
pub fn TextMapSetter(comptime Carrier: type) type {
    return struct {
        /// Set a key-value pair in the carrier.
        /// Should preserve casing for the key.
        setFn: *const fn (carrier: *Carrier, key: []const u8, value: []const u8) anyerror!void,

        const Self = @This();

        pub fn set(self: Self, carrier: *Carrier, key: []const u8, value: []const u8) !void {
            return self.setFn(carrier, key, value);
        }
    };
}

// HTTP Header Carriers

/// StringHashMap-based HTTP header carrier getter
pub fn HttpHeaderGetter(headers: *const std.StringHashMap([]const u8), key: []const u8) ?[]const u8 {
    // Case-insensitive lookup
    var it = headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, key)) {
            return entry.value_ptr.*;
        }
    }
    return null;
}

/// Get all keys from HTTP headers (for StringHashMap carrier)
pub fn HttpHeaderKeys(headers: *const std.StringHashMap([]const u8)) []const []const u8 {
    _ = headers;
    // TODO: return the header names. Building the slice needs an allocator,
    // which `keysFn` does not take yet; that signature change is a follow-up.
    return &[_][]const u8{};
}

/// StringHashMap-based HTTP header carrier setter.
///
/// Stores `value` without copying it: propagators allocate the values they
/// inject, and the owner of the map is responsible for freeing them.
pub fn HttpHeaderSetter(headers: *std.StringHashMap([]const u8), key: []const u8, value: []const u8) !void {
    try headers.put(key, value);
}

/// Create a TextMapGetter for StringHashMap-based HTTP headers
pub const HttpGetter = TextMapGetter(std.StringHashMap([]const u8)){
    .getFn = HttpHeaderGetter,
    .keysFn = HttpHeaderKeys,
};

/// Create a TextMapSetter for StringHashMap-based HTTP headers
pub const HttpSetter = TextMapSetter(std.StringHashMap([]const u8)){
    .setFn = HttpHeaderSetter,
};

test "http header getter is case insensitive" {
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();

    try headers.put("TraceParent", "value");

    try std.testing.expectEqualStrings("value", HttpGetter.get(&headers, "traceparent").?);
    try std.testing.expect(HttpGetter.get(&headers, "tracestate") == null);
}
