//! Sampling decisions for spans created by the SDK Tracer.
//!
//! https://opentelemetry.io/docs/specs/otel/trace/sdk/#sampling

const std = @import("std");

const trace = @import("../../api/trace.zig");

/// Outcome of a sampling decision.
/// `record_only` records the span but leaves the sampled flag unset; none of
/// the built-in samplers return it.
pub const Decision = enum {
    drop,
    record_only,
    record_and_sample,
};

/// Inputs to a sampling decision. A struct so that the fields the
/// specification allows a sampler to read (name, kind, attributes, links)
/// can be added later without touching every call site.
pub const Params = struct {
    parent: ?trace.SpanContext,
    trace_id: trace.TraceID,
};

/// Compile-time dispatch over the built-in samplers.
pub const Sampler = union(enum) {
    always_on,
    always_off,
    trace_id_ratio: TraceIdRatio,
    parent_based: ParentBased,

    const Self = @This();

    /// Delegate consulted by `parent_based` when there is no valid parent.
    /// A separate type rather than a pointer to Sampler: parent_based is
    /// never its own root.
    pub const Root = union(enum) {
        always_on,
        always_off,
        trace_id_ratio: TraceIdRatio,

        fn shouldSample(self: Root, params: Params) Decision {
            return switch (self) {
                .always_on => .record_and_sample,
                .always_off => .drop,
                .trace_id_ratio => |ratio| ratio.shouldSample(params),
            };
        }
    };

    pub const ParentBased = struct {
        root: Root,
    };

    pub const TraceIdRatio = struct {
        ratio: f64,

        fn shouldSample(self: TraceIdRatio, params: Params) Decision {
            // NaN would trap in @intFromFloat; parseRatio never produces it.
            std.debug.assert(!std.math.isNan(self.ratio));
            if (self.ratio >= 1.0) return .record_and_sample;
            if (self.ratio <= 0.0) return .drop;

            // W3C Trace Context Level 2 only guarantees randomness in the 7
            // rightmost bytes, so the eighth from the right must not
            // influence the decision.
            // See https://github.com/open-telemetry/opentelemetry-specification/blob/v1.48.0/specification/trace/sdk.md#traceidratiobased-sampler-algorithm
            const max_randomness: f64 = @floatFromInt(@as(u64, 1) << 56);
            const threshold: u64 = @intFromFloat((1.0 - self.ratio) * max_randomness);
            const randomness = std.mem.readInt(u56, params.trace_id.value[9..16], .big);
            return if (randomness >= threshold) .record_and_sample else .drop;
        }
    };

    pub fn shouldSample(self: Self, params: Params) Decision {
        return switch (self) {
            .always_on => .record_and_sample,
            .always_off => .drop,
            .trace_id_ratio => |ratio| ratio.shouldSample(params),
            .parent_based => |parent_based| {
                if (params.parent) |parent| {
                    if (parent.isValid()) {
                        return if (parent.trace_flags.isSampled()) .record_and_sample else .drop;
                    }
                }
                return parent_based.root.shouldSample(params);
            },
        };
    }

    /// Build the sampler named by OTEL_TRACES_SAMPLER, with `arg` taken from
    /// OTEL_TRACES_SAMPLER_ARG. Returns null when the name is not one the
    /// specification defines, leaving the caller to report it.
    pub fn fromString(name: []const u8, arg: ?[]const u8) ?Self {
        const eql = std.ascii.eqlIgnoreCase;

        if (eql(name, "always_on")) return .always_on;
        if (eql(name, "always_off")) return .always_off;
        if (eql(name, "traceidratio")) return .{ .trace_id_ratio = .{ .ratio = parseRatio(arg) } };
        if (eql(name, "parentbased_always_on")) return .{ .parent_based = .{ .root = .always_on } };
        if (eql(name, "parentbased_always_off")) return .{ .parent_based = .{ .root = .always_off } };
        if (eql(name, "parentbased_traceidratio")) {
            return .{ .parent_based = .{ .root = .{ .trace_id_ratio = .{ .ratio = parseRatio(arg) } } } };
        }
        // Named by the specification, not implemented here: warn rather than
        // silently sampling differently from what the user asked for.
        if (eql(name, "jaeger_remote") or eql(name, "parentbased_jaeger_remote") or eql(name, "xray")) {
            std.log.warn("OTEL_TRACES_SAMPLER={s} is not implemented, falling back to parentbased_always_on", .{name});
            return default();
        }
        return null;
    }

    /// The default mandated by the specification when OTEL_TRACES_SAMPLER is unset.
    pub fn default() Self {
        return .{ .parent_based = .{ .root = .always_on } };
    }

    /// The specification requires falling back to 1.0 when the argument is
    /// missing or not a ratio in [0, 1].
    fn parseRatio(arg: ?[]const u8) f64 {
        const raw = arg orelse return 1.0;
        const ratio = std.fmt.parseFloat(f64, raw) catch std.math.nan(f64);
        if (ratio >= 0.0 and ratio <= 1.0) return ratio;
        std.log.warn("OTEL_TRACES_SAMPLER_ARG={s} is not a valid ratio, using 1.0", .{raw});
        return 1.0;
    }
};

const testing = std.testing;

fn testParent(sampled: bool) trace.SpanContext {
    return trace.SpanContext.init(
        trace.TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
        trace.SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        if (sampled) trace.TraceFlags.sampled() else trace.TraceFlags.default(),
        undefined,
        true,
    );
}

fn testParams(parent: ?trace.SpanContext) Params {
    return .{
        .parent = parent,
        .trace_id = trace.TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }),
    };
}

test "always_on and always_off ignore the parent" {
    const on: Sampler = .always_on;
    const off: Sampler = .always_off;

    for ([_]?trace.SpanContext{ null, testParent(true), testParent(false) }) |parent| {
        try testing.expectEqual(Decision.record_and_sample, on.shouldSample(testParams(parent)));
        try testing.expectEqual(Decision.drop, off.shouldSample(testParams(parent)));
    }
}

test "parent_based follows a valid parent" {
    const sampler = Sampler{ .parent_based = .{ .root = .always_off } };

    try testing.expectEqual(Decision.record_and_sample, sampler.shouldSample(testParams(testParent(true))));
    try testing.expectEqual(Decision.drop, sampler.shouldSample(testParams(testParent(false))));
}

test "parent_based delegates to root without a valid parent" {
    const sampler = Sampler{ .parent_based = .{ .root = .always_on } };

    // No parent at all.
    try testing.expectEqual(Decision.record_and_sample, sampler.shouldSample(testParams(null)));

    // Parent present but invalid: all-zero IDs.
    const invalid = trace.SpanContext.init(
        trace.TraceID.zero(),
        trace.SpanID.zero(),
        trace.TraceFlags.default(),
        undefined,
        false,
    );
    try testing.expectEqual(Decision.record_and_sample, sampler.shouldSample(testParams(invalid)));
}

test "trace_id_ratio bounds" {
    const all = Sampler{ .trace_id_ratio = .{ .ratio = 1.0 } };
    const none = Sampler{ .trace_id_ratio = .{ .ratio = 0.0 } };

    try testing.expectEqual(Decision.record_and_sample, all.shouldSample(testParams(null)));
    try testing.expectEqual(Decision.drop, none.shouldSample(testParams(null)));
}

test "trace_id_ratio compares only the 56 rightmost trace ID bits" {
    const sampler = Sampler{ .trace_id_ratio = .{ .ratio = 0.5 } };

    // Byte 8 is not guaranteed random and must not sway the decision.
    var low = testParams(null);
    low.trace_id = trace.TraceID.init([_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0xff, 0x0f, 0, 0, 0, 0, 0, 0 });
    try testing.expectEqual(Decision.drop, sampler.shouldSample(low));

    var high = testParams(null);
    high.trace_id = trace.TraceID.init([_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0x00, 0xf0, 0, 0, 0, 0, 0, 0 });
    try testing.expectEqual(Decision.record_and_sample, sampler.shouldSample(high));
}

test "trace_id_ratio samples roughly the configured fraction" {
    const sampler = Sampler{ .trace_id_ratio = .{ .ratio = 0.25 } };

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var sampled: usize = 0;
    const total = 10_000;
    for (0..total) |_| {
        var raw: [16]u8 = undefined;
        random.bytes(&raw);
        var params = testParams(null);
        params.trace_id = trace.TraceID.init(raw);
        if (sampler.shouldSample(params) == .record_and_sample) sampled += 1;
    }

    // 2500 expected
    try testing.expect(sampled > 2000 and sampled < 3000);
}

test "fromString maps every sampler name" {
    const cases = [_]struct { name: []const u8, arg: ?[]const u8, expected: Sampler }{
        .{ .name = "always_on", .arg = null, .expected = .always_on },
        .{ .name = "always_off", .arg = null, .expected = .always_off },
        .{ .name = "traceidratio", .arg = "0.25", .expected = .{ .trace_id_ratio = .{ .ratio = 0.25 } } },
        .{ .name = "parentbased_always_on", .arg = null, .expected = .{ .parent_based = .{ .root = .always_on } } },
        .{ .name = "parentbased_always_off", .arg = null, .expected = .{ .parent_based = .{ .root = .always_off } } },
        .{
            .name = "parentbased_traceidratio",
            .arg = "0.5",
            .expected = .{ .parent_based = .{ .root = .{ .trace_id_ratio = .{ .ratio = 0.5 } } } },
        },
        // Named by the specification but unimplemented: fall back to the default.
        .{ .name = "jaeger_remote", .arg = null, .expected = .{ .parent_based = .{ .root = .always_on } } },
        .{ .name = "parentbased_jaeger_remote", .arg = null, .expected = .{ .parent_based = .{ .root = .always_on } } },
        .{ .name = "xray", .arg = null, .expected = .{ .parent_based = .{ .root = .always_on } } },
        // Names are matched case-insensitively.
        .{ .name = "ALWAYS_OFF", .arg = null, .expected = .always_off },
    };

    for (cases) |case| {
        try testing.expectEqual(case.expected, Sampler.fromString(case.name, case.arg).?);
    }

    try testing.expectEqual(@as(?Sampler, null), Sampler.fromString("not_a_sampler", null));
}

test "fromString falls back to a ratio of 1.0 on a bad argument" {
    const expected = Sampler{ .trace_id_ratio = .{ .ratio = 1.0 } };

    for ([_]?[]const u8{ null, "not-a-number", "-1", "1.5", "nan", "inf" }) |arg| {
        try testing.expectEqual(expected, Sampler.fromString("traceidratio", arg).?);
    }
}
