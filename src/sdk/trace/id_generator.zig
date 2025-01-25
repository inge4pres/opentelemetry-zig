const trace = @import("../../api/trace.zig");
/// IDGenerator is the interface that generates traceID/spanID.
pub const IDGenerator = struct {
    newIDsFn: *const fn (
        *IDGenerator,
    ) TraceSpanID,
    newSpanIDFn: *const fn (
        *IDGenerator,
        trace_id: trace.TraceID,
    ) trace.SpanID,
};

/// TraceSpanID is the set of traceID/spanID.
pub const TraceSpanID = struct {
    traceID: trace.TraceID,
    spanID: trace.SpanID,
};

/// RandomIDGenerator generates traceID/spanID randomly.
pub const RandomIDGenerator = struct {
    const Self = @This();
    pub fn init() Self {
        return .{};
    }
};
