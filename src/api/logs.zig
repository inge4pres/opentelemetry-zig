pub const EnabledParameters = @import("logs/enabled_parameters.zig").EnabledParameters;

test {
    _ = @import("logs/logger_provider.zig");
    _ = @import("logs/enabled_parameters.zig");
}
