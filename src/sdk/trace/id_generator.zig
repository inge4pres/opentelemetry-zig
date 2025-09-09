const std = @import("std");

const trace = @import("../../api/trace.zig");

/// Compile-time dispatch to generate traceID/spanID.
pub const IDGenerator = union(enum) {
    Random: RandomIDGenerator,
    TimeBased: TimeBasedIDGenerator,

    const Self = @This();

    pub fn newIDs(self: Self) TraceSpanID {
        return switch (self) {
            inline else => |gen| gen.newIDs(),
        };
    }

    pub fn newSpanID(self: Self, trace_id: trace.TraceID) trace.SpanID {
        return switch (self) {
            inline else => |gen| gen.newSpanID(trace_id),
        };
    }
};

/// TraceSpanID is the set of traceID/spanID.
pub const TraceSpanID = struct {
    trace_id: trace.TraceID,
    span_id: trace.SpanID,
};

/// An implementation of IDGenerator that generates traceID/spanID randomly.
pub const RandomIDGenerator = struct {
    const Self = @This();

    random: std.Random,

    pub fn init(random: std.Random) Self {
        return .{
            .random = random,
        };
    }

    pub fn newIDs(self: Self) TraceSpanID {
        var trace_span_id = TraceSpanID{
            .trace_id = trace.TraceID.init(undefined),
            .span_id = trace.SpanID.init(undefined),
        };
        while (true) {
            var raw_trace_id: [16]u8 = undefined;
            self.random.bytes(raw_trace_id[0..raw_trace_id.len]);

            const trace_id = trace.TraceID.init(raw_trace_id);
            if (trace_id.isValid()) {
                trace_span_id.trace_id = trace_id;
                break;
            }
        }

        while (true) {
            var raw_span_id: [8]u8 = undefined;
            self.random.bytes(raw_span_id[0..raw_span_id.len]);

            const span_id = trace.SpanID.init(raw_span_id);
            if (span_id.isValid()) {
                trace_span_id.span_id = span_id;
                break;
            }
        }

        return trace_span_id;
    }

    pub fn newSpanID(self: Self, _: trace.TraceID) trace.SpanID {
        while (true) {
            var raw_span_id: [8]u8 = undefined;
            self.random.bytes(raw_span_id[0..raw_span_id.len]);
            const span_id = trace.SpanID.init(raw_span_id);

            if (span_id.isValid()) {
                return span_id;
            }
        }
    }
};

test "RandomIDGenerator newIDs" {
    const seed = 0;
    var default_prng = std.Random.DefaultPrng.init(seed);
    var random_generator = RandomIDGenerator.init(default_prng.random());

    for (0..1000) |_| {
        const trace_span_id = random_generator.newIDs();

        try std.testing.expect(trace_span_id.trace_id.isValid());
        try std.testing.expect(trace_span_id.span_id.isValid());
    }
}

test "RandomIDGenerator newSpanID" {
    const seed = 0;
    var default_prng = std.Random.DefaultPrng.init(seed);
    var random_generator = RandomIDGenerator.init(default_prng.random());

    for (0..1000) |_| {
        const span_id = random_generator.newSpanID(trace.TraceID.init(undefined));

        try std.testing.expect(span_id.isValid());
    }
}

pub const TimeBasedIDGenerator = struct {
    magic: i64 = 0xDEADBEEF,

    const Self = @This();

    pub fn newIDs(self: Self) TraceSpanID {
        const timestamp = std.time.nanoTimestamp();
        const trace_id: i128 = timestamp ^ self.magic;
        const span_id: i64 = @truncate(timestamp & trace_id);
        return TraceSpanID{
            .trace_id = trace.TraceID.init(std.mem.toBytes(trace_id)),
            .span_id = trace.SpanID.init(std.mem.toBytes(span_id)),
        };
    }

    pub fn newSpanID(self: Self, trace_id: trace.TraceID) trace.SpanID {
        const lower: i64 = @truncate(std.time.nanoTimestamp() ^ self.magic);

        // Mix with trace_id to reduce collision
        var lower_array = std.mem.toBytes(lower);
        const trace_origin = trace_id.value[8..];
        for (4..8) |i| {
            lower_array[i] ^= trace_origin[i];
        }
        return trace.SpanID.init(lower_array);
    }
};

test "TimeBasedIDGenerator newIDs" {
    var time_based_generator = TimeBasedIDGenerator{};

    for (0..1000) |_| {
        const trace_span_id = time_based_generator.newIDs();

        try std.testing.expect(trace_span_id.trace_id.isValid());
        try std.testing.expect(trace_span_id.span_id.isValid());
    }
}

test "TimeBasedIDGenerator newSpanID" {
    var time_based_generator = TimeBasedIDGenerator{ .magic = 0xFFFFFFFFFFFF };

    for (0..1000) |_| {
        const span_id = time_based_generator.newSpanID(trace.TraceID.init(undefined));

        try std.testing.expect(span_id.isValid());
    }
}
