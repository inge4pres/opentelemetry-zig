const std = @import("std");
const metrics = @import("metrics.zig");

/// FormatError is an error type that is used to represent errors in the format of the data.
pub const FormatError = error{
    InvalidName,
    invalidUnit,
    InvalidDescription,
};

/// Validate the instrument options are conformant to the OpenTelemetry specification.
/// The name, unit and description of the instrument are validated in sequence.
pub fn validateInstrumentOptions(opts: ?metrics.InstrumentOptions) !void {
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
