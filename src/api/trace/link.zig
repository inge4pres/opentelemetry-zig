const Attribute = @import("../../attributes.zig").Attribute;
const trace = @import("../trace.zig");

pub const Link = struct {
    span_context: trace.SpanContext,
    attributes: []Attribute,

    pub fn init(span_context: trace.SpanContext, attrs: []Attribute) Link {
        return Link{
            .span_context = span_context,
            .attributes = attrs,
        };
    }
};
