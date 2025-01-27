const attributes = @import("../../attributes.zig");
pub const Link = struct {
    // TODO
    // span_context: trace.SpanContext,

    attributes: []attributes.Attribute,
};
