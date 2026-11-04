//! OpenTelemetry Baggage Propagators.
//!
//! This module implements the W3C Baggage specification for propagating baggage
//! across process boundaries via HTTP headers and environment variables.
//!
//! W3C Baggage Format: key1=value1;metadata,key2=value2;metadata
//! - Keys and values are URL-encoded
//! - Metadata is optional and follows a semicolon. It is opaque: it is neither
//!   encoded nor decoded, so the caller percent-encodes whatever needs it. It
//!   cannot hold a `,` or a control character (see `error.InvalidBaggageMetadata`)
//! - Multiple entries are comma-separated
//!
//! Example usage:
//! ```zig
//! const propagator = @import("opentelemetry-sdk").api.baggage.propagator;
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
const propagator = @import("../propagation.zig");

/// W3C Baggage header name
pub const baggage_header = "baggage";

/// Environment variable name for baggage
pub const baggage_env_var = "BAGGAGE";

/// Fields read and written by this propagator
pub fn fields() []const []const u8 {
    return &.{baggage_header};
}

/// Formats `raw` percent-encoded according to RFC 3986: everything but
/// `ALPHA / DIGIT / "-" / "." / "_" / "~"` becomes an uppercase `%XX` escape.
fn urlEncode(raw: []const u8) std.fmt.Alt(std.Uri.Component, std.Uri.Component.formatEscaped) {
    return std.fmt.alt(std.Uri.Component{ .raw = raw }, .formatEscaped);
}

/// Percent-decode `input` according to RFC 3986: `%XX` escapes are decoded and
/// a malformed one is kept verbatim. A literal `+` stays a `+`: the W3C Baggage
/// specification gives it no special meaning, and a space is encoded as `%20`.
///
/// The input is left untouched; the result is written into `buffer`, which must
/// hold at least `input.len` bytes (decoding never grows a string). The returned
/// slice points into `buffer`.
fn urlDecode(buffer: []u8, input: []const u8) []u8 {
    return std.Uri.percentDecodeBackwards(buffer[0..input.len], input);
}

/// Inject baggage into a carrier using the W3C Baggage format.
///
/// ## Parameters
/// - `allocator`: Memory allocator for temporary strings
/// - `baggage`: The Baggage to inject
/// - `carrier`: The carrier to inject into (e.g., HTTP headers)
/// - `setter`: The TextMapSetter for the carrier type
///
/// An entry's metadata is opaque and written as is, after the `;` that follows
/// its value. The caller must therefore provide it already percent-encoded where
/// needed, for example `%20` for a space in a property value. It cannot hold a `,`,
/// which would start another entry, or a control character, which would corrupt the
/// header. Empty metadata is not written.
///
/// ## Errors
/// - `OutOfMemory`: If allocation fails during encoding
/// - `InvalidBaggageMetadata`: If an entry's metadata holds a `,` or a control
///   character. Nothing is injected.
/// - Carrier-specific errors from the setter
pub fn inject(
    allocator: std.mem.Allocator,
    baggage: Baggage,
    carrier: anytype,
    setter: propagator.TextMapSetter(@TypeOf(carrier.*)),
) !void {
    return injectWithKey(allocator, baggage, carrier, setter, baggage_header);
}

fn injectWithKey(
    allocator: std.mem.Allocator,
    baggage: Baggage,
    carrier: anytype,
    setter: propagator.TextMapSetter(@TypeOf(carrier.*)),
    key: []const u8,
) !void {
    if (baggage.count() == 0) {
        return; // Nothing to inject
    }

    const owned_slice = try formatBaggage(allocator, baggage);
    setter.set(carrier, key, owned_slice) catch |err| {
        allocator.free(owned_slice);
        return err;
    };
}

/// Whether `metadata` can be written to a baggage header as is: it must not hold a
/// `,`, which would start another entry, nor a control character, as CR and LF would
/// split the header. A tab is whitespace and is accepted.
fn isValidMetadata(metadata: []const u8) bool {
    for (metadata) |c| switch (c) {
        ',', 0x00...0x08, 0x0A...0x1F, 0x7F => return false,
        else => {},
    };
    return true;
}

fn formatBaggage(allocator: std.mem.Allocator, baggage: Baggage) ![]u8 {
    var header_value: std.ArrayList(u8) = .empty;
    errdefer header_value.deinit(allocator);

    var first = true;
    var it = baggage.iterator();
    while (it.next()) |entry| {
        if (!first) {
            try header_value.append(allocator, ',');
        }
        first = false;

        try header_value.print(allocator, "{f}={f}", .{
            urlEncode(entry.key_ptr.*),
            urlEncode(entry.value_ptr.value),
        });

        // Add metadata if present, verbatim: it is opaque
        if (entry.value_ptr.metadata) |metadata| {
            if (!isValidMetadata(metadata)) return error.InvalidBaggageMetadata;
            if (metadata.len > 0) try header_value.print(allocator, ";{s}", .{metadata});
        }
    }

    return try header_value.toOwnedSlice(allocator);
}

/// Extract baggage from a carrier using the W3C Baggage format.
///
/// ## Parameters
/// - `allocator`: Memory allocator for the new baggage
/// - `carrier`: The carrier to extract from (e.g., HTTP headers)
/// - `getter`: The TextMapGetter for the carrier type
///
/// An entry's metadata is opaque and kept exactly as received. If it holds a control
/// character (see `inject`), only the metadata is dropped and the entry is kept, so
/// that what was extracted can always be injected again.
///
/// ## Returns
/// The extracted Baggage, or null if no baggage header is present.
///
/// ## Errors
/// - `OutOfMemory`: If allocation fails during extraction
pub fn extract(
    allocator: std.mem.Allocator,
    carrier: anytype,
    getter: propagator.TextMapGetter(@TypeOf(carrier.*)),
) !?Baggage {
    const header_value = getter.get(carrier, baggage_header) orelse return null;
    return try parseBaggageHeader(allocator, header_value);
}

fn parseBaggageHeader(allocator: std.mem.Allocator, header_value: []const u8) !?Baggage {
    if (header_value.len == 0) {
        return Baggage.init();
    }

    var baggage = Baggage.init();
    errdefer baggage.deinit();

    // The decoded key and value of one entry never take more room than the header
    // does, so each entry can decode into the start of this buffer.
    const scratch = try allocator.alloc(u8, header_value.len);
    defer allocator.free(scratch);

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

        // Decode key and value one after the other into the scratch buffer
        const key = urlDecode(scratch, entry.name);
        const value = urlDecode(scratch[entry.name.len..], encoded_value);

        // Metadata is opaque: kept as received, neither decoded nor parsed further.
        // Invalid metadata is dropped rather than the entry, and anything kept can
        // be injected again. This is network input, so it may well be sloppy.
        const raw_metadata = std.mem.trim(u8, parts.rest(), &std.ascii.whitespace);
        const metadata: ?[]const u8 = if (raw_metadata.len > 0 and isValidMetadata(raw_metadata)) raw_metadata else null;

        // Add to baggage
        baggage.setValue(allocator, key, value, metadata) catch continue;
    }

    return baggage;
}

// Carriers (re-exported from the shared propagation module)

pub const TextMapGetter = propagator.TextMapGetter;
pub const TextMapSetter = propagator.TextMapSetter;
pub const HttpHeaderGetter = propagator.HttpHeaderGetter;
pub const HttpHeaderKeys = propagator.HttpHeaderKeys;
pub const HttpHeaderSetter = propagator.HttpHeaderSetter;
pub const HttpGetter = propagator.HttpGetter;
pub const HttpSetter = propagator.HttpSetter;

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
pub const EnvGetter = propagator.TextMapGetter(EnvMap){
    .getFn = EnvironmentGetter,
    .keysFn = EnvironmentKeys,
};

/// Create a TextMapSetter for environment variables
pub const EnvSetter = propagator.TextMapSetter(EnvMap){
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
    const header_value = env_map.get(baggage_env_var) orelse return null;
    return try parseBaggageHeader(allocator, header_value);
}

/// Inject baggage into an environment map.
///
/// This sets the BAGGAGE environment variable with the W3C-encoded baggage.
///
/// ## Parameters
/// - `allocator`: Memory allocator for encoding
/// - `baggage`: The Baggage to inject
/// - `env_map`: The environment map to inject into
///
/// ## Errors
/// - `OutOfMemory`: If allocation fails during encoding
pub fn injectIntoEnvironment(
    allocator: std.mem.Allocator,
    baggage: Baggage,
    env_map: *EnvMap,
) !void {
    if (baggage.count() == 0) return;
    const value = try formatBaggage(allocator, baggage);
    defer allocator.free(value);
    try env_map.put(baggage_env_var, value);
}

// Tests
test "url encoding" {
    const allocator = std.testing.allocator;

    const encoded = try std.fmt.allocPrint(allocator, "{f}", .{urlEncode("hello world")});
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("hello%20world", encoded);

    const encoded2 = try std.fmt.allocPrint(allocator, "{f}", .{urlEncode("user@example.com")});
    defer allocator.free(encoded2);
    try std.testing.expectEqualStrings("user%40example.com", encoded2);

    const encoded3 = try std.fmt.allocPrint(allocator, "{f}", .{urlEncode("safe-chars_123.~")});
    defer allocator.free(encoded3);
    try std.testing.expectEqualStrings("safe-chars_123.~", encoded3);

    // Only unreserved characters are left as they are, so `+` is escaped too.
    const encoded4 = try std.fmt.allocPrint(allocator, "{f}", .{urlEncode("a+b")});
    defer allocator.free(encoded4);
    try std.testing.expectEqualStrings("a%2Bb", encoded4);
}

test "url decoding" {
    var buffer: [32]u8 = undefined;

    try std.testing.expectEqualStrings("hello world", urlDecode(&buffer, "hello%20world"));
    try std.testing.expectEqualStrings("user@example.com", urlDecode(&buffer, "user%40example.com"));
}

test "url decoding keeps a literal + as is" {
    var buffer: [32]u8 = undefined;

    try std.testing.expectEqualStrings("hello+world", urlDecode(&buffer, "hello+world"));
    try std.testing.expectEqualStrings("a+b+c d", urlDecode(&buffer, "a%2Bb+c%20d"));
}

test "url decoding keeps malformed escapes verbatim" {
    var buffer: [32]u8 = undefined;

    try std.testing.expectEqualStrings("100%", urlDecode(&buffer, "100%"));
    try std.testing.expectEqualStrings("truncated%2", urlDecode(&buffer, "truncated%2"));
    try std.testing.expectEqualStrings("%ZZ+ok", urlDecode(&buffer, "%ZZ+ok"));
}

test "url decoding leaves the input untouched" {
    var input = "a+b%20c".*;
    var buffer: [input.len]u8 = undefined;

    try std.testing.expectEqualStrings("a+b c", urlDecode(&buffer, &input));
    try std.testing.expectEqualStrings("a+b%20c", &input);
}

test "url encode/decode round trip" {
    const allocator = std.testing.allocator;

    const original = "test=value;metadata,special@chars#here";
    const encoded = try std.fmt.allocPrint(allocator, "{f}", .{urlEncode(original)});
    defer allocator.free(encoded);

    const buffer = try allocator.alloc(u8, encoded.len);
    defer allocator.free(buffer);

    try std.testing.expectEqualStrings(original, urlDecode(buffer, encoded));
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

test "inject writes metadata verbatim" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "account_id", "12345", "priority=high");
    defer baggage.deinit();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| allocator.free(value.*);
        headers.deinit();
    }

    try inject(allocator, baggage, &headers, HttpSetter);

    // The `=` of a property is not escaped, or a receiver would not see a property.
    try std.testing.expectEqualStrings("account_id=12345;priority=high", headers.get("baggage").?);
}

test "inject keeps the properties of a metadata and percent sequences in it" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "key", "value", "k1=v1;k2;k3=a%2Cb");
    defer baggage.deinit();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| allocator.free(value.*);
        headers.deinit();
    }

    try inject(allocator, baggage, &headers, HttpSetter);

    try std.testing.expectEqualStrings("key=value;k1=v1;k2;k3=a%2Cb", headers.get("baggage").?);
}

test "inject does not write empty metadata" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "key", "value", "");
    defer baggage.deinit();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| allocator.free(value.*);
        headers.deinit();
    }

    try inject(allocator, baggage, &headers, HttpSetter);

    try std.testing.expectEqualStrings("key=value", headers.get("baggage").?);
}

test "inject writes whitespace and other non-structural characters as is" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "key", "value", "p1 = a b ; p2=\"q\"\tx");
    defer baggage.deinit();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| allocator.free(value.*);
        headers.deinit();
    }

    try inject(allocator, baggage, &headers, HttpSetter);

    try std.testing.expectEqualStrings("key=value;p1 = a b ; p2=\"q\"\tx", headers.get("baggage").?);
}

test "inject rejects metadata that would corrupt the header" {
    const allocator = std.testing.allocator;

    const invalid = [_][]const u8{ "a,b", "new\nline", "carriage\rreturn", "ctl\x01", "nul\x00", "del\x7f" };
    for (invalid) |metadata| {
        var baggage = Baggage.init();
        try baggage.setValue(allocator, "key", "value", metadata);
        defer baggage.deinit();

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer headers.deinit();

        try std.testing.expectError(error.InvalidBaggageMetadata, inject(allocator, baggage, &headers, HttpSetter));
        // Nothing is injected, not even the entries before the invalid one.
        try std.testing.expectEqual(0, headers.count());
    }
}

test "inject rejects invalid metadata on a later entry without leaking" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "good", "1", "p=1");
    try baggage.setValue(allocator, "bad", "2", "a,b");
    defer baggage.deinit();

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try std.testing.expectError(error.InvalidBaggageMetadata, inject(allocator, baggage, &headers, HttpSetter));
    try std.testing.expectEqual(0, headers.count());
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

test "extract keeps a literal '+' in values and does not turn it into a space" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    // '+' is a valid `baggage-octet`; only `%20` encodes a space.
    try headers.put("baggage", "email=a+b@example.com,name=Jane%20Doe+Smith");

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    try std.testing.expectEqualStrings("a+b@example.com", extracted.getValue("email").?.value);
    try std.testing.expectEqualStrings("Jane Doe+Smith", extracted.getValue("name").?.value);
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

test "extract keeps metadata verbatim without decoding it" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    // Percent sequences and '+' in a property are opaque, unlike in a value.
    try headers.put("baggage", "plain=a%20b;k%3Dv,second=2 ; p1=x+y;p2=%2C ");

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    const plain = extracted.getValue("plain").?;
    try std.testing.expectEqualStrings("a b", plain.value);
    try std.testing.expectEqualStrings("k%3Dv", plain.metadata.?);

    const second = extracted.getValue("second").?;
    try std.testing.expectEqualStrings("2", second.value);
    try std.testing.expectEqualStrings("p1=x+y;p2=%2C", second.metadata.?);
}

test "extract drops invalid metadata but keeps the entry" {
    const allocator = std.testing.allocator;

    const invalid = [_][]const u8{
        "k=v;a=b\x01c",
        "k=v;a=b\x7fc",
        "k=v;a=b\nc",
        "k=v;a=b\rc",
    };
    for (invalid) |header| {
        var headers = std.StringHashMap([]const u8).init(allocator);
        defer headers.deinit();
        try headers.put("baggage", header);

        var extracted = (try extract(allocator, &headers, HttpGetter)).?;
        defer extracted.deinit();

        try std.testing.expectEqual(1, extracted.count());
        const entry = extracted.getValue("k").?;
        try std.testing.expectEqualStrings("v", entry.value);
        try std.testing.expect(entry.metadata == null);
    }
}

test "extract keeps whitespace in metadata as received" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    // Metadata is opaque: spaces around properties, and inside them, are not touched.
    try headers.put("baggage", "k = v ;\tp1 = a%20b ; p2 ;p3=c d ");

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();

    const entry = extracted.getValue("k").?;
    try std.testing.expectEqualStrings("v", entry.value);
    try std.testing.expectEqualStrings("p1 = a%20b ; p2 ;p3=c d", entry.metadata.?);
}

test "extracted baggage can always be injected again" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    // The first entry's metadata is invalid, the second one's is fine.
    try headers.put("baggage", "user=alice;note=a\x01b,team=blue;p=1");

    var extracted = (try extract(allocator, &headers, HttpGetter)).?;
    defer extracted.deinit();
    try std.testing.expectEqual(2, extracted.count());

    var out = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = out.valueIterator();
        while (value_it.next()) |value| allocator.free(value.*);
        out.deinit();
    }
    try inject(allocator, extracted, &out, HttpSetter);

    var again = (try extract(allocator, &out, HttpGetter)).?;
    defer again.deinit();

    try std.testing.expectEqualStrings("alice", again.getValue("user").?.value);
    try std.testing.expect(again.getValue("user").?.metadata == null);
    try std.testing.expectEqualStrings("blue", again.getValue("team").?.value);
    try std.testing.expectEqualStrings("p=1", again.getValue("team").?.metadata.?);
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

test "propagator fields" {
    const f = fields();
    try std.testing.expectEqual(@as(usize, 1), f.len);
    try std.testing.expectEqualStrings("baggage", f[0]);
}

test "inject and extract baggage with environment variables" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "user_id", "alice", null);
    try baggage.setValue(allocator, "plan", "pro", "level=1");
    defer baggage.deinit();

    var env_map = EnvMap.init(allocator);
    defer env_map.deinit();

    try injectIntoEnvironment(allocator, baggage, &env_map);

    // BAGGAGE should be set, but lowercase "baggage" should not
    try std.testing.expect(env_map.get("BAGGAGE") != null);
    try std.testing.expect(env_map.get("baggage") == null);

    // Extract from environment
    var extracted = (try extractFromEnvironment(allocator, &env_map)).?;
    defer extracted.deinit();

    try std.testing.expectEqual(@as(usize, 2), extracted.count());
    try std.testing.expectEqualStrings("alice", extracted.getValue("user_id").?.value);
    try std.testing.expectEqualStrings("pro", extracted.getValue("plan").?.value);
    try std.testing.expectEqualStrings("level=1", extracted.getValue("plan").?.metadata.?);
}
