const std = @import("std");

/// Iterator over `name<kv_separator>value` pairs joined by `separator`,
/// e.g. `key1=value1,key2=value2` for `KeyValueSequenceIterator(',', '=')`.
///
/// Names and values are trimmed of surrounding ASCII whitespace. Blank entries
/// are skipped, but malformed ones are still reported so that callers can warn
/// about them: an entry with no `kv_separator` yields a null `value`, and an
/// entry starting with `kv_separator` yields an empty `name`.
///
/// The *first* `kv_separator` separates the name from the value, so a value
/// may contain further ones (`a=b=c` yields `a` / `b=c`).
///
/// The iterator borrows the buffer passed to `init`; the returned slices point
/// into it and are valid for as long as it is.
///
/// A list of plain values rather than assignments needs none of this: reach for
/// `std.mem.tokenizeScalar` with a `std.mem.trim` per item instead.
pub fn KeyValueSequenceIterator(comptime separator: u8, comptime kv_separator: u8) type {
    return struct {
        // tokenizeScalar (rather than splitScalar) already skips empty entries,
        // which covers `a=b,,c=d` and a trailing separator.
        iterator: std.mem.TokenIterator(u8, .scalar),

        const Self = @This();

        /// A single `name<kv_separator>value` pair.
        pub const Entry = struct {
            name: []const u8,
            /// Null when the entry carries no `kv_separator` at all, as opposed to
            /// an empty slice for an entry such as `name=`.
            value: ?[]const u8,
        };

        pub fn init(buffer: []const u8) Self {
            return .{ .iterator = std.mem.tokenizeScalar(u8, buffer, separator) };
        }

        /// Returns the next entry, or null once the buffer is exhausted.
        pub fn next(self: *Self) ?Entry {
            while (self.iterator.next()) |assignment| {
                const entry = trim(assignment);
                // A whitespace-only entry has nothing worth reporting.
                if (entry.len == 0) continue;

                const index = std.mem.indexOfScalar(u8, entry, kv_separator) orelse {
                    return .{ .name = entry, .value = null };
                };
                return .{ .name = trim(entry[0..index]), .value = trim(entry[index + 1 ..]) };
            }
            return null;
        }

        /// Rewinds the iterator to the start of the buffer.
        pub fn reset(self: *Self) void {
            self.iterator.reset();
        }

        fn trim(slice: []const u8) []const u8 {
            return std.mem.trim(u8, slice, &std.ascii.whitespace);
        }
    };
}

/// Iterator over comma-separated `name=value` pairs, the shape taken by most
/// OTel environment variables that carry assignments: `OTEL_RESOURCE_ATTRIBUTES`,
/// `OTEL_EXPORTER_OTLP_HEADERS`, W3C `tracestate` and `baggage` entries.
pub const CommaSeparatedAssignmentIterator = KeyValueSequenceIterator(',', '=');

fn expectEntry(
    expected_name: []const u8,
    expected_value: ?[]const u8,
    actual: ?CommaSeparatedAssignmentIterator.Entry,
) !void {
    const entry = actual orelse return error.TestExpectedEntry;
    try std.testing.expectEqualStrings(expected_name, entry.name);
    if (expected_value) |expected| {
        try std.testing.expectEqualStrings(expected, entry.value orelse return error.TestExpectedValue);
    } else {
        try std.testing.expectEqual(null, entry.value);
    }
}

test CommaSeparatedAssignmentIterator {
    const env_var = "foo=bar,bar=baz,,toto=tata,";

    var it: CommaSeparatedAssignmentIterator = .init(env_var);
    try expectEntry("foo", "bar", it.next());
    try expectEntry("bar", "baz", it.next());
    try expectEntry("toto", "tata", it.next());
    try std.testing.expectEqual(null, it.next());
    // Exhaustion is sticky.
    try std.testing.expectEqual(null, it.next());
}

test "values may be empty or contain the kv_separator" {
    var it: CommaSeparatedAssignmentIterator = .init("empty=,equation=a=b+c");

    try expectEntry("empty", "", it.next());
    try expectEntry("equation", "a=b+c", it.next());
    try std.testing.expectEqual(null, it.next());
}

test "iterating to exhaustion" {
    var it: CommaSeparatedAssignmentIterator = .init("a=1,b=2,c=3");

    var count: usize = 0;
    while (it.next()) |entry| : (count += 1) {
        try std.testing.expectEqual(1, entry.name.len);
        try std.testing.expectEqual(1, (entry.value orelse return error.TestExpectedValue).len);
    }
    try std.testing.expectEqual(3, count);
}

test "surrounding whitespace is trimmed" {
    var it: CommaSeparatedAssignmentIterator = .init(" foo = bar ,\tbar\t=\tbaz\t,  novalue  ");

    try expectEntry("foo", "bar", it.next());
    try expectEntry("bar", "baz", it.next());
    try expectEntry("novalue", null, it.next());
    try std.testing.expectEqual(null, it.next());
}

test "malformed entries are reported, not skipped" {
    var it: CommaSeparatedAssignmentIterator = .init("novalue,=orphan,foo=bar");

    // A missing kv_separator is distinguishable from an empty value.
    try expectEntry("novalue", null, it.next());
    try expectEntry("", "orphan", it.next());
    // Iteration carries on past them.
    try expectEntry("foo", "bar", it.next());
    try std.testing.expectEqual(null, it.next());
}

test "blank input yields nothing" {
    for ([_][]const u8{ "", ",", " , ", " ,\t,\n" }) |input| {
        var it: CommaSeparatedAssignmentIterator = .init(input);
        try std.testing.expectEqual(null, it.next());
    }
}

test "reset rewinds the iterator" {
    var it: CommaSeparatedAssignmentIterator = .init("foo=bar,bar=baz");

    while (it.next()) |_| {}
    try std.testing.expectEqual(null, it.next());

    it.reset();
    try expectEntry("foo", "bar", it.next());
}
