const std = @import("std");

pub const EnvMap = std.process.Environ.Map;

fn currentEnvironBlock() std.process.Environ.Block {
    if (@hasDecl(std.process.Environ.Block, "global")) {
        return std.process.Environ.Block.global;
    }

    var env_count: usize = 0;
    while (std.c.environ[env_count] != null) : (env_count += 1) {}
    const environ: [:null]const ?[*:0]const u8 = @ptrCast(std.c.environ[0..env_count :null]);
    return .{ .slice = environ };
}

pub fn createEnvMap(allocator: std.mem.Allocator) !EnvMap {
    return std.process.Environ.createMap(.{ .block = currentEnvironBlock() }, allocator);
}
