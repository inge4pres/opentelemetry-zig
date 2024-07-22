const std = @import("std");

/// FormatError is an error type that is used to represent errors in the format of the data.
pub const FormatError = error{
    InvalidInstrumentName,
};

/// Validate the name of the instrument is conformant to the OpenTelemetry specification.
/// Specification is defined at https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-name-syntax
pub fn validateName(name: []const u8) FormatError!void {
    if (name.len == 0) {
        return FormatError.InvalidInstrumentName;
    }
    if (name.len > 255) {
        return FormatError.InvalidInstrumentName;
    }
    if (std.ascii.isDigit(name[0])) {
        return FormatError.InvalidInstrumentName;
    }
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            switch (c) {
                '_', '-', '.', '/' => continue,
                else => return FormatError.InvalidInstrumentName,
            }
        }
    }
    return;
}
