const std = @import("std");
const zon = @import("build.zig.zon");

const helpers = @import("build/helpers.zig");
const sdk_build = @import("build/sdk/build.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const benchmarks_mod = b.dependency("zbench", .{}).module("zbench");

    // OpenTelemetry proto package ships protobuf as a dependency so we'll use it.
    const otel_pb_dep = b.dependency("opentelemetry_proto", .{});

    const otel_proto_mod = otel_pb_dep.module("opentelemetry-proto");
    const protobuf_mod = otel_pb_dep.builder.dependency("protobuf", .{
        .optimize = optimize,
        .target = target,
    }).module("protobuf");

    var sdk_build_mods = helpers.BuildModules.init(b.allocator);
    defer sdk_build_mods.deinit();

    try sdk_build_mods.put("protobuf", protobuf_mod);
    try sdk_build_mods.put("opentelemetry-proto", otel_proto_mod);
    try sdk_build_mods.put("benchmark", benchmarks_mod);

    const compilation_info = helpers.CompilationInfo{
        .target = target,
        .optimize = optimize,
        .pkg_name = @tagName(zon.name),
        .version = zon.version,
    };

    try sdk_build.Setup(b, compilation_info, &sdk_build_mods);
}
