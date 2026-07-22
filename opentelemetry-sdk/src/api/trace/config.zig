const Attribute = @import("../../attributes.zig").Attribute;

/// TracerConfig is a group of options for a Tracer.
pub const TracerConfig = struct {
    /// Version of the instrumentation scope
    version: ?[]const u8 = null,
    /// Schema URL that should be recorded in the emitted telemetry
    schema_url: ?[]const u8 = null,
    /// Instrumentation scope attributes to associate with emitted telemetry
    attributes: ?[]const Attribute = null,
};
