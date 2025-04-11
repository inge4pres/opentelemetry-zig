const Attribute = @import("./attributes.zig").Attribute;

/// Instrumentation Scope is a logical unit of the application code with which the emitted telemetry can be associated
/// see: https://opentelemetry.io/docs/specs/otel/glossary/#instrumentation-scope
pub const InstrumentationScope = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    schema_url: ?[]const u8 = null,
    attributes: ?[]Attribute = null,
};