//! Root of every SDK example executable: runs the example's `main` with a
//! leak-checked allocator. std/start.zig reports leaks of `init.gpa` but keeps
//! the exit code at zero, so leaks would never fail `sdk-run-examples`.

const std = @import("std");
const example = @import("example");

// Only the root module's `std_options` is honored.
pub const std_options: std.Options = if (@hasDecl(example, "std_options")) example.std_options else .{};

pub fn main(init: std.process.Init) !void {
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer if (safe.deinit() > 0) std.process.exit(1);

    var checked = init;
    checked.gpa = safe.allocator();
    return example.main(checked);
}
