//! OpenTelemetry Baggage Propagators.
//!
//! This module implements the W3C Baggage specification for propagating baggage
//! across process boundaries via HTTP headers and environment variables.
//!
//! W3C Baggage Format: key1=value1;metadata,key2=value2;metadata
//! - Keys and values are URL-encoded
//! - Metadata is optional and follows a semicolon
//! - Multiple entries are comma-separated
//!
//! Example usage:
//! ```zig
//! const propagator = @import("opentelemetry").baggage.propagator;
//!
//! // HTTP Header propagation
//! var headers = std.StringHashMap([]const u8).init(allocator);
//! try propagator.inject(allocator, my_baggage, &headers, HttpSetter);
//!
//! const extracted = try propagator.extract(allocator, &headers, HttpGetter);
//! ```
const std = @import("std");
const EnvMap = std.process.Environ.Map;
const Baggage = @import("../baggage.zig").Baggage;
const BaggageEntry = @import("../baggage.zig").BaggageEntry;
const CommaSeparatedAssignmentIterator = @import("../../sdk/key_value_sequence_iterator.zig").CommaSeparatedAssignmentIterator;

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

/// W3C Baggage header name
pub const baggage_header = "baggage";

/// Environment variable name for baggage
pub const baggage_env_var = "BAGGAGE";

/// URL-encode a string according to RFC 3986.
fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try result.append(allocator, c);
        } else {
            try result.append(allocator, '%');
            try result.print(allocator, "{X:0>2}", .{c});
        }
    }

    return result.toOwnedSlice(allocator);
}

/// URL-decode a string.
fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex, 16) catch {
                // Invalid encoding, keep the percent sign
                try result.append(allocator, '%');
                i += 1;
                continue;
            };
            try result.append(allocator, byte);
            i += 3;
        } else if (input[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Inject baggage into a carrier using the W3C Baggage format.
///
/// ## Parameters
/// - `allocator`: Memory allocator for temporary strings
/// - `baggage`: The Baggage to inject
/// - `carrier`: The carrier to inject into (e.g., HTTP headers)
/// - `setter`: The TextMapSetter for the carrier type
///
/// ## Errors
/// - `OutOfMemory`: If allocation fails during encoding
/// - Carrier-specific errors from the setter
pub fn inject(
    allocator: std.mem.Allocator,
    baggage: Baggage,
    carrier: anytype,
    setter: TextMapSetter(@TypeOf(carrier.*)),
) !void {
    if (baggage.count() == 0) {
        return; // Nothing to inject
    }

    var header_value: std.ArrayList(u8) = .empty;
    errdefer header_value.deinit(allocator);

    var first = true;
    var it = baggage.iterator();
    while (it.next()) |entry| {
        if (!first) {
            try header_value.append(allocator, ',');
        }
        first = false;

        // Encode key and value
        const encoded_key = try urlEncode(allocator, entry.key_ptr.*);
        defer allocator.free(encoded_key);

        const encoded_value = try urlEncode(allocator, entry.value_ptr.value);
        defer allocator.free(encoded_value);

        try header_value.print(allocator, "{s}={s}", .{ encoded_key, encoded_value });

        // Add metadata if present
        if (entry.value_ptr.metadata) |metadata| {
            const encoded_metadata = try urlEncode(allocator, metadata);
            defer allocator.free(encoded_metadata);
            try header_value.print(allocator, ";{s}", .{encoded_metadata});
        }
    }

    const owned_slice = try header_value.toOwnedSlice(allocator);
    try setter.set(carrier, baggage_header, owned_slice);
}

/// Extract baggage from a carrier using the W3C Baggage format.
///
/// ## Parameters
/// - `allocator`: Memory allocator for the new baggage
/// - `carrier`: The carrier to extract from (e.g., HTTP headers)
/// - `getter`: The TextMapGetter for the carrier type
///
/// ## Returns
/// The extracted Baggage, or null if no baggage header is present.
///
/// ## Errors
/// - `OutOfMemory`: If allocation fails during extraction
pub fn extract(
    allocator: std.mem.Allocator,
    carrier: anytype,
    getter: TextMapGetter(@TypeOf(carrier.*)),
) !?Baggage {
    const header_value = getter.get(carrier, baggage_header) orelse return null;

    if (header_value.len == 0) {
        return Baggage.init();
    }

    var baggage = Baggage.init();
    errdefer baggage.deinit();

    // A baggage header is a list of assignments whose values carry an optional
    // `;metadata` tail. Neither a key nor a value may hold a raw `,` or `;`.
    var entries: CommaSeparatedAssignmentIterator = .init(header_value);
    while (entries.next()) |entry| {
        // Empty key or value is skipped
        // A `;` in the key means the member never began with an assignment => empty key
        if (entry.name.len == 0 or std.mem.indexOfScalar(u8, entry.name, ';') != null or entry.value == null) continue;

        var parts = std.mem.splitScalar(u8, entry.value orelse unreachable, ';');
        const encoded_value = std.mem.trim(u8, parts.first(), &std.ascii.whitespace);
        if (encoded_value.len == 0) continue;

        // Decode key and value
        const key = urlDecode(allocator, entry.name) catch continue;
        defer allocator.free(key);

        const value = urlDecode(allocator, encoded_value) catch continue;
        defer allocator.free(value);

        // Get metadata if present, kept verbatim rather than parsed further
        const encoded_metadata = std.mem.trim(u8, parts.rest(), &std.ascii.whitespace);
        const metadata = if (encoded_metadata.len > 0)
            urlDecode(allocator, encoded_metadata) catch null
        else
            null;
        defer if (metadata) |m| allocator.free(m);

        // Add to baggage
        baggage.setValue(allocator, key, value, metadata) catch continue;
    }

    return baggage;
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
    // Return empty slice - keys() method not needed for basic propagation
    return &[_][]const u8{};
}

/// StringHashMap-based HTTP header carrier setter
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

// Environment Variable Carriers

/// Environment map getter
pub fn EnvironmentGetter(env_map: *const EnvMap, key: []const u8) ?[]const u8 {
    return env_map.get(key);
}

/// Get all environment variable keys
pub fn EnvironmentKeys(env_map: *const EnvMap) []const []const u8 {
    _ = env_map;
    // Return empty slice - keys() method not needed for basic propagation
    return &[_][]const u8{};
}

/// Environment map setter
pub fn EnvironmentSetter(env_map: *EnvMap, key: []const u8, value: []const u8) !void {
    try env_map.put(key, value);
}

/// Create a TextMapGetter for environment variables
pub const EnvGetter = TextMapGetter(EnvMap){
    .getFn = EnvironmentGetter,
    .keysFn = EnvironmentKeys,
};

/// Create a TextMapSetter for environment variables
pub const EnvSetter = TextMapSetter(EnvMap){
    .setFn = EnvironmentSetter,
};

/// Extract baggage from the BAGGAGE environment variable.
///
/// ## Parameters
/// - `allocator`: Memory allocator for the new baggage
/// - `env_map`: Environment map to read BAGGAGE from
///
/// ## Returns
/// The extracted Baggage, or null if BAGGAGE env var is not set.
///
/// ## Errors
/// - `OutOfMemory`: If allocation fails during extraction
pub fn extractFromEnvironment(allocator: std.mem.Allocator, env_map: *const EnvMap) !?Baggage {
    return try extract(allocator, env_map, EnvGetter);
}

/// Inject baggage into an environment map.
///
/// This sets the BAGGAGE environment variable with the W3C-encoded baggage.
///
/// ## Parameters
/// - `allocator`: Memory allocator for encoding
/// - `baggage`: The Baggage to inject
/// - `env`: The environment map to inject into
///
/// ## Errors
/// - `OutOfMemory`: If allocation fails during encoding
pub fn injectIntoEnvironment(
    allocator: std.mem.Allocator,
    baggage: Baggage,
    env_map: *EnvMap,
) !void {
    try inject(allocator, baggage, env_map, EnvSetter);
}

// Tests
test "url encoding" {
    const allocator = std.testing.allocator;

    const encoded = try urlEncode(allocator, "hello world");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("hello%20world", encoded);

    const encoded2 = try urlEncode(allocator, "user@example.com");
    defer allocator.free(encoded2);
    try std.testing.expectEqualStrings("user%40example.com", encoded2);

    const encoded3 = try urlEncode(allocator, "safe-chars_123.~");
    defer allocator.free(encoded3);
    try std.testing.expectEqualStrings("safe-chars_123.~", encoded3);
}

test "url decoding" {
    const allocator = std.testing.allocator;

    const decoded = try urlDecode(allocator, "hello%20world");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world", decoded);

    const decoded2 = try urlDecode(allocator, "user%40example.com");
    defer allocator.free(decoded2);
    try std.testing.expectEqualStrings("user@example.com", decoded2);

    const decoded3 = try urlDecode(allocator, "hello+world");
    defer allocator.free(decoded3);
    try std.testing.expectEqualStrings("hello world", decoded3);
}

test "url encode/decode round trip" {
    const allocator = std.testing.allocator;

    const original = "test=value;metadata,special@chars#here";
    const encoded = try urlEncode(allocator, original);
    defer allocator.free(encoded);

    const decoded = try urlDecode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "inject and extract simple baggage" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "user_id", "alice", null);
    defer baggage.deinit();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        headers.deinit();
    }

    try inject(allocator, baggage, &headers, HttpSetter);

    const header_value = headers.get("baggage").?;
    try std.testing.expect(std.mem.indexOf(u8, header_value, "user_id=alice") != null);

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    const entry = extracted.getValue("user_id").?;
    try std.testing.expectEqualStrings("alice", entry.value);
    try std.testing.expect(entry.metadata == null);
}

test "inject and extract baggage with metadata" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "account_id", "12345", "priority=high");
    defer baggage.deinit();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        headers.deinit();
    }

    try inject(allocator, baggage, &headers, HttpSetter);

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    const entry = extracted.getValue("account_id").?;
    try std.testing.expectEqualStrings("12345", entry.value);
    try std.testing.expectEqualStrings("priority=high", entry.metadata.?);
}

test "inject and extract multiple entries" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "key1", "value1", null);
    try baggage.setValue(allocator, "key2", "value2", "meta2");
    try baggage.setValue(allocator, "key3", "value3", null);
    defer baggage.deinit();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        headers.deinit();
    }

    try inject(allocator, baggage, &headers, HttpSetter);

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    try std.testing.expectEqual(@as(usize, 3), extracted.count());
    try std.testing.expectEqualStrings("value1", extracted.getValue("key1").?.value);
    try std.testing.expectEqualStrings("value2", extracted.getValue("key2").?.value);
    try std.testing.expectEqualStrings("value3", extracted.getValue("key3").?.value);
    try std.testing.expectEqualStrings("meta2", extracted.getValue("key2").?.metadata.?);
}

test "inject and extract with special characters" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "user email", "alice@example.com", null);
    defer baggage.deinit();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        headers.deinit();
    }

    try inject(allocator, baggage, &headers, HttpSetter);

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    const entry = extracted.getValue("user email").?;
    try std.testing.expectEqualStrings("alice@example.com", entry.value);
}

test "extract empty baggage" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    const extracted = try extract(allocator, &headers, HttpGetter);
    try std.testing.expect(extracted == null);
}

test "extract malformed baggage" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("baggage", "invalid-no-equals");

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    // Should extract an empty baggage since the format is invalid
    try std.testing.expectEqual(@as(usize, 0), extracted.count());
}

test "extract strips whitespace around separators" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    // The grammar allows optional whitespace around ',', '=' and ';'.
    try headers.put("baggage", " key1 = value1 ; meta1 , key2 = value2 ");

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    try std.testing.expectEqual(@as(usize, 2), extracted.count());

    const first = extracted.getValue("key1").?;
    try std.testing.expectEqualStrings("value1", first.value);
    try std.testing.expectEqualStrings("meta1", first.metadata.?);

    const second = extracted.getValue("key2").?;
    try std.testing.expectEqualStrings("value2", second.value);
    try std.testing.expect(second.metadata == null);
}

test "extract keeps '=' inside values and metadata" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    // '=' is a legal baggage octet, so only the first one splits the pair.
    try headers.put("baggage", "equation=a=b,account=12345;priority=high");

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    try std.testing.expectEqual(@as(usize, 2), extracted.count());
    try std.testing.expectEqualStrings("a=b", extracted.getValue("equation").?.value);

    const account = extracted.getValue("account").?;
    try std.testing.expectEqualStrings("12345", account.value);
    try std.testing.expectEqualStrings("priority=high", account.metadata.?);
}

test "extract skips a member with an empty value" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    // An empty value is dropped whether or not metadata follows it.
    try headers.put("baggage", "bare=,spaced= ;meta,key=value");

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    try std.testing.expectEqual(@as(usize, 1), extracted.count());
    try std.testing.expectEqualStrings("value", extracted.getValue("key").?.value);
}

test "extract skips a member that does not begin with an assignment" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("baggage", ";orphan=value,key=value");

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    // The leading ';' lands in the key, which marks the member as malformed.
    try std.testing.expectEqual(@as(usize, 1), extracted.count());
    try std.testing.expectEqualStrings("value", extracted.getValue("key").?.value);
}

test "http header case insensitive" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("Baggage", "key=value");

    const value = HttpHeaderGetter(&headers, "baggage");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("key=value", value.?);
}

test "inject empty baggage does nothing" {
    const allocator = std.testing.allocator;

    const baggage = Baggage.init();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        headers.deinit();
    }

    try inject(allocator, baggage, &headers, HttpSetter);

    try std.testing.expect(headers.get("baggage") == null);
}
