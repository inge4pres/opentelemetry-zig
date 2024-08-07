const std = @import("std");
const pbcommon = @import("../opentelemetry/proto/common/v1.pb.zig");
const pbutils = @import("../pbutils.zig");

const MeterProvider = @import("meter.zig").MeterProvider;
const MeterOptions = @import("meter.zig").MeterOptions;
const InstrumentOptions = @import("instrument.zig").InstrumentOptions;

/// FormatError is an error type that is used to represent errors in the format of the data.
pub const FormatError = error{
    InvalidName,
    invalidUnit,
    InvalidDescription,
    InvalidExplicitBucketBoundaries,
};

/// Validate the instrument options are conformant to the OpenTelemetry specification.
/// The name, unit and description of the instrument are validated in sequence.
pub fn validateInstrumentOptions(opts: ?InstrumentOptions) !void {
    if (opts) |o| {
        try validateName(o.name);
        try validateUnit(o.unit);
        try validateDescription(o.description);
    }
}

// Validate the name of the instrument is conformant to the OpenTelemetry specification.
// Specification is defined at https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-name-syntax
fn validateName(name: []const u8) FormatError!void {
    if (name.len == 0) {
        return FormatError.InvalidName;
    }
    if (name.len > 255) {
        return FormatError.InvalidName;
    }
    if (std.ascii.isDigit(name[0])) {
        return FormatError.InvalidName;
    }
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            switch (c) {
                '_', '-', '.', '/' => continue,
                else => return FormatError.InvalidName,
            }
        }
    }
    return;
}

test "instrument name must conform to the OpenTelemetry specification" {
    const longname = "longname" ** 32;
    const invalid_names = &[_][]const u8{
        "0invalid",
        "wrongchar()",
        // 256 chars exceeds the limit
        longname,
    };
    for (invalid_names) |name| {
        const err = validateName(name);
        try std.testing.expectEqual(FormatError.InvalidName, err);
    }
}

test "meter cannot create instrument if name does not conform to the OpenTelemetry specification" {
    const mp = try MeterProvider.default();
    defer mp.deinit();
    const m = try mp.getMeter(.{ .name = "my-meter" });
    const invalid_names = &[_][]const u8{
        // Does not start with a letter
        "123",
        // null or empty string
        "",
        // contains invalid characters
        "alpha-?",
    };
    for (invalid_names) |name| {
        const r = m.createCounter(i32, .{ .name = name });
        try std.testing.expectError(FormatError.InvalidName, r);
    }
}

// Validate the unit of the instrument is conformant to the OpenTelemetry specification.
// See https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-unit
fn validateUnit(unit: ?[]const u8) FormatError!void {
    if (unit) |u| {
        if (u.len > 63) {
            return FormatError.invalidUnit;
        }
        for (u) |c| {
            if (!std.ascii.isASCII(c)) {
                return FormatError.invalidUnit;
            }
        }
    }
}

test "validate unit" {
    const longunit = "longunit" ** 8;
    const invalid_units = &[_][]const u8{
        // 64 chars exceeds the limit
        longunit,
        // non-ascii character
        "°C",
    };
    for (invalid_units) |unit| {
        const err = validateUnit(unit);
        try std.testing.expectEqual(FormatError.invalidUnit, err);
    }
}

// Validate instrument description is conformant to the OpenTelemetry specification.
// See https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-description
fn validateDescription(description: ?[]const u8) FormatError!void {
    if (description) |d| {
        if (d.len > 1023) {
            return FormatError.InvalidDescription;
        }
        if (!std.unicode.utf8ValidateSlice(d)) {
            return FormatError.InvalidDescription;
        }
    }
}

test "validate description" {
    const longdesc = "longdesc" ** 128;
    const invalid_descs = &[_][]const u8{
        // 1024 chars exceeds the limit
        longdesc,
        // invalid utf-8
        "\xf0\x28\x8c\x28",
    };
    for (invalid_descs) |desc| {
        const err = validateDescription(desc);
        try std.testing.expectEqual(FormatError.InvalidDescription, err);
    }
}

/// ResourceError indicates that there is a problem in the access of the resoruce.
pub const ResourceError = error{
    MeterExistsWithDifferentAttributes,
    InstrumentExistsWithSameName,
};

/// Generate an identifier for a meter: an existing meter with same
/// name, version and schemUrl cannot be created again with different attributes.
pub fn meterIdentifier(options: MeterOptions) u64 {
    var hash: [2048]u8 = std.mem.zeroes([2048]u8);
    var nextInsertIdx: usize = 0;
    const keys = [_][]const u8{ options.name, options.version, options.schema_url orelse "" };
    for (keys) |k| {
        for (k) |b| {
            hash[nextInsertIdx] = b;
        }
        nextInsertIdx += k.len;
    }
    return std.hash.XxHash3.hash(0, &hash);
}

test "meter identifier" {
    const name = "my-meter";
    const version = "v1.2.3";
    const schema_url = "http://foo.bar";

    const id = meterIdentifier(.{ .name = name, .version = version, .schema_url = schema_url });
    std.debug.assert(id == 0xf5938ee137020d5e);
}

test "meter identifier changes with different schema url" {
    const name = "my-meter";
    const version = "v1.2.3";
    const schema_url = "http://foo.bar";
    const schema_url2 = "http://foo.baz";

    const id = meterIdentifier(.{ .name = name, .version = version, .schema_url = schema_url });
    const id2 = meterIdentifier(.{ .name = name, .version = version, .schema_url = schema_url2 });
    std.debug.assert(id != id2);
}

/// Identify an instrument in a meter by its name, kind, unit and description.
/// Used to recognize duplicate instrument registration as defined in
/// https://opentelemetry.io/docs/specs/otel/metrics/sdk/#duplicate-instrument-registration.
/// Returned identifier must be freed by the caller using the allocator.
pub fn instrumentIdentifier(allocator: std.mem.Allocator, name: []const u8, kind: []const u8, unit: []const u8, description: []const u8) ![]u8 {
    var h = std.hash.Wyhash.init(42);
    h.update(description);
    const id = h.final();
    return try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{x}", .{ lowerCaseName(name), kind, unit, id });
}

/// All instrument names must be case-insensitive.
pub fn lowerCaseName(name: []const u8) []u8 {
    var lowName: [255]u8 = [_]u8{0} ** 255;
    for (name, 0..name.len) |c, i| {
        lowName[i] = std.ascii.toLower(c);
    }
    return lowName[0..name.len];
}

test "identifying field for instrument remain equal upon similar name with mixed case" {
    const name: []const u8 = "BytesCounter";
    const equivalentName: []const u8 = "bytesCounter";
    const kind: []const u8 = "Counter(i64)/sync";
    const description: []const u8 = "some interesting counter for bytes";
    const alloc = std.testing.allocator;

    const a = try instrumentIdentifier(alloc, name, kind, "", description);
    defer alloc.free(a);
    const b = try instrumentIdentifier(alloc, equivalentName, kind, "", description);
    defer alloc.free(b);
    std.debug.assert(std.mem.eql(u8, a, b));
}

test "identifying fields for instruments change with unit" {

    // Name, kind,unit and description must uniquely identify an instrument in a meter
    const name: []const u8 = "bytes-counter";
    const kind: []const u8 = "Counter(i64)/sync";
    const description: []const u8 = "some interesting counter for bytes";
    const alloc = std.testing.allocator;

    const a = try instrumentIdentifier(alloc, name, kind, "", description);
    defer alloc.free(a);
    const b = try instrumentIdentifier(alloc, name, kind, "bytes", description);
    defer alloc.free(b);
    std.debug.assert(!std.mem.eql(u8, a, b));
}

// Represents the default histogram bucket boundaries as documented in the OpenTelemetry specification.
// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#explicit-bucket-histogram-aggregation
pub const defaultHistogramBucketBoundaries: []const f64 = &[_]f64{ 0.0, 5.0, 10.0, 25.0, 50.0, 75.0, 100.0, 250.0, 500.0, 750.0, 1000.0, 2500.0, 5000.0, 7500.0, 10000.0 };

/// Validate the histogram option to use explicit bucket boundaries is conformant to the OpenTelemetry specification.
/// Bucket boundaries must be between 0 and a positive real number, and in increasing order.
/// There is no theoretical limit on the number of buckets, but the number of buckets should be kept small (usually between 5 and 20).
pub fn validateExplicitBuckets(buckets: []const f64) FormatError!void {
    if (buckets.len == 0) {
        return FormatError.InvalidExplicitBucketBoundaries;
    }
    var prev = buckets[0];
    for (1..buckets.len) |i| {
        if (buckets[i] <= prev) {
            return FormatError.InvalidExplicitBucketBoundaries;
        }
        prev = buckets[i];
    }
}

test "validate default buckets" {
    const err = validateExplicitBuckets(defaultHistogramBucketBoundaries);
    try std.testing.expectEqual({}, err);
}

test "validate explicit buckets" {
    const invalid_buckets = &[_][]const f64{
        // empty buckets
        &[_]f64{},
        // not in increasing order
        &[_]f64{ 0.0, 1.0, 0.5 },
    };
    for (invalid_buckets) |buckets| {
        const err = validateExplicitBuckets(buckets);
        try std.testing.expectEqual(FormatError.InvalidExplicitBucketBoundaries, err);
    }
}
