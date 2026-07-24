const std = @import("std");
const zon = @import("build.zig.zon");

const helpers = @import("build/helpers.zig");
const proto_build = @import("build/proto/build.zig");
const sdk_build = @import("build/sdk/build.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const benchmarks_mod = b.dependency("zbench", .{}).module("zbench");
    const protobuf_mod = b.dependency("protobuf", .{
        .optimize = optimize,
        .target = target,
    }).module("protobuf");

    var build_mods = helpers.BuildModules.init(b.allocator);
    defer build_mods.deinit();

    try build_mods.put("protobuf", protobuf_mod);
    try build_mods.put("benchmark", benchmarks_mod);

    const compilation_info = helpers.CompilationInfo{
        .target = target,
        .optimize = optimize,
        .pkg_name = @tagName(zon.name),
        .version = zon.version,
    };

    // proto exposes the "opentelemetry-proto" module the SDK imports.
    try proto_build.Setup(b, compilation_info, &build_mods);
    try sdk_build.Setup(b, compilation_info, &build_mods);
}
