pub const StdOutExporter = @import("generic.zig").StdoutExporter;
pub const InMemoryExporter = @import("generic.zig").InMemoryExporter;

test {
    _ = @import("generic.zig");
}
