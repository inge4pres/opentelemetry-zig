const std = @import("std");

const trace = @import("../../api/trace.zig");
/// IDGenerator is the interface that generates traceID/spanID.
pub const IDGenerator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const Self = @This();

    /// VTable defines the methods that the SpanExporter's instance must implement.
    pub const VTable = struct {
        newIDsFn: *const fn (ctx: *anyopaque) TraceSpanID,
        newSpanIDFn: *const fn (ctx: *anyopaque, trace_id: trace.TraceID) trace.SpanID,
    };

    pub fn newIDs(self: Self) TraceSpanID {
        return self.vtable.newIDsFn(self.ptr);
    }

    pub fn newSpanID(self: Self, trace_id: trace.TraceID) trace.SpanID {
        return self.vtable.newSpanIDFn(self.ptr, trace_id);
    }
};

/// TraceSpanID is the set of traceID/spanID.
pub const TraceSpanID = struct {
    trace_id: trace.TraceID,
    span_id: trace.SpanID,
};

/// RandomIDGenerator generates traceID/spanID randomly.
pub const RandomIDGenerator = struct {
    const Self = @This();

    random: std.Random,

    pub fn init(random: std.Random) Self {
        return .{
            .random = random,
        };
    }

    pub fn asIDGenerator(self: *Self) IDGenerator {
        return .{
            .ptr = self,
            .vtable = &.{
                .newIDsFn = newIDs,
                .newSpanIDFn = newSpanID,
            },
        };
    }

    pub fn newIDs(ctx: *anyopaque) TraceSpanID {
        const self: *Self = @ptrCast(@alignCast(ctx));

        var raw_trace_id: [16]u8 = undefined;
        while (true) {
            self.random.bytes(raw_trace_id[0..raw_trace_id.len]);

            if (trace.TraceID.isValidValue(raw_trace_id)) {
                break;
            }
        }
        var raw_span_id: [8]u8 = undefined;
        while (true) {
            self.random.bytes(raw_span_id[0..raw_span_id.len]);

            if (trace.SpanID.isValidValue(raw_span_id)) {
                break;
            }
        }

        return .{
            .trace_id = trace.TraceID.init(raw_trace_id),
            .span_id = trace.SpanID.init(raw_span_id),
        };
    }

    pub fn newSpanID(ctx: *anyopaque, _: trace.TraceID) trace.SpanID {
        const self: *Self = @ptrCast(@alignCast(ctx));

        var raw_span_id: [8]u8 = undefined;
        while (true) {
            self.random.bytes(raw_span_id[0..raw_span_id.len]);

            if (trace.SpanID.isValidValue(raw_span_id)) {
                break;
            }
        }

        return trace.SpanID.init(raw_span_id);
    }
};

test "RandomIDGenerator newIDs" {
    const seed = 0;
    var default_prng = std.Random.DefaultPrng.init(seed);
    var random_generator = RandomIDGenerator.init(default_prng.random());
    var generator = random_generator.asIDGenerator();

    const n = 1000;

    for (0..n) |_| {
        const trace_span_id = generator.newIDs();

        try std.testing.expect(trace_span_id.trace_id.isValid());
        try std.testing.expect(trace_span_id.span_id.isValid());
    }
}

test "RandomIDGenerator newSpanID" {
    const seed = 0;
    var default_prng = std.Random.DefaultPrng.init(seed);
    var random_generator = RandomIDGenerator.init(default_prng.random());
    var generator = random_generator.asIDGenerator();

    const n = 1000;

    for (0..n) |_| {
        const span_id = generator.newSpanID(trace.TraceID.init(undefined));

        try std.testing.expect(span_id.isValid());
    }
}
