const std = @import("std");

pub fn getZigFileName(file_name: []const u8) ?[]const u8 {
    // Get the file name without extension, checking if it ends with '.zig'.
    // If it doesn't end in 'zig' then ignore.
    const index = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return null;
    if (index == 0) return null; // discard dotfiles
    if (!std.mem.eql(u8, file_name[index + 1 ..], "zig")) return null;
    return file_name[0..index];
}

pub const BuildModules = std.StringHashMap(*std.Build.Module);

// Generates a ist of imports from a BuildModules map, only including the modules whose names are in the `include` list.
// It returns an error if an entry in `include` is not found in the `source` map.
pub fn ImportsFromBuildModules(allocator: std.mem.Allocator, source: *const BuildModules, include_list: [][]const u8) ![]std.Build.Module.Import {
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    errdefer imports.deinit(allocator);

    for (include_list) |name| {
        const mod = source.get(name) orelse {
            std.debug.print("Failed to find module {s} for imports\n", .{name});
            return BuildError.ModuleNotFound;
        };
        try imports.append(allocator, .{ .name = name, .module = mod });
    }

    return try imports.toOwnedSlice(allocator);
}

pub const BuildError = error{
    DependencyNotFound,
    ModuleNotFound,
};

pub const CompilationInfo = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: []const u8,
    pkg_name: []const u8,
};
