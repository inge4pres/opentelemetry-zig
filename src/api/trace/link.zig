const Attribute = @import("../../attributes.zig").Attribute;
const trace = @import("../trace.zig");

/// Link represents a link to another Span
pub const Link = struct {
    span_context: trace.SpanContext,
    attributes: []Attribute,

    const Self = @This();

    pub fn init(span_context: trace.SpanContext, attrs: []Attribute) Self {
        return Self{
            .span_context = span_context,
            .attributes = attrs,
        };
    }
};
