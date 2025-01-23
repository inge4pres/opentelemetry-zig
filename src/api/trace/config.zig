/// TracerConfig is a group of options for a Tracer.
pub const TracerConfig = struct {
    instrumentation_version: []const u8,
    schema_url: []const u8,
};
