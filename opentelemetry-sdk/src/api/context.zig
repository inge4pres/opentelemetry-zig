/// OpenTelemetry Context API.
///
/// Example usage:
/// ```zig
/// const context = @import("opentelemetry").context; // Assuming sdk.zig is the entrypoint
/// const key = context.createKey("user_id");
/// var ctx = try context.Context.init().setValue(std.heap.page_allocator, key, .{ .string = "alice" });
/// defer ctx.deinit();
/// ```
pub const Context = @import("context/context.zig").Context;
pub const ContextKey = @import("context/context.zig").ContextKey;
pub const createKey = @import("context/context.zig").createKey;
pub const Key = @import("context/context.zig").Key;
pub const getCurrentContext = @import("context/context.zig").getCurrentContext;
pub const attachContext = @import("context/context.zig").attachContext;
pub const detachContext = @import("context/context.zig").detachContext;
pub const cleanup = @import("context/context.zig").cleanup;
pub const DetachError = @import("context/context.zig").DetachError;
pub const Token = @import("context/context.zig").Token;

test {
    _ = @import("context/context.zig");
}
