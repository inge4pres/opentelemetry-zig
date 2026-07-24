const std = @import("std");
const protobuf = @import("protobuf");
const helpers = @import("../helpers.zig");

const BuildError = helpers.BuildError;
const BuildModules = helpers.BuildModules;
const CompilationInfo = helpers.CompilationInfo;

// Path of the vendored OpenTelemetry proto source root relative to build.zig.
const proto_root = "opentelemetry-proto";

// OpenTelemetry proto definitions to generate Zig bindings from, relative to
// the proto-src submodule root. Add entries here as the API grows.
const proto_files = [_][]const u8{
    // Signals
    "opentelemetry/proto/common/v1/common.proto",
    "opentelemetry/proto/resource/v1/resource.proto",
    "opentelemetry/proto/metrics/v1/metrics.proto",
    "opentelemetry/proto/trace/v1/trace.proto",
    "opentelemetry/proto/logs/v1/logs.proto",
    "opentelemetry/proto/profiles/v1development/profiles.proto",
    // Collector types for OTLP
    "opentelemetry/proto/collector/metrics/v1/metrics_service.proto",
    "opentelemetry/proto/collector/trace/v1/trace_service.proto",
    "opentelemetry/proto/collector/logs/v1/logs_service.proto",
    "opentelemetry/proto/collector/profiles/v1development/profiles_service.proto",
};

// Sets up the opentelemetry-proto module from the vendored generated bindings
// and registers its build steps. The created module is added to `dependencies`
// so other modules (e.g. the SDK) can import it.
pub fn Setup(
    b: *std.Build,
    info: CompilationInfo,
    dependencies: *BuildModules,
) !void {
    const protobuf_mod = dependencies.get("protobuf") orelse return BuildError.ModuleNotFound;

    const proto_mod = b.addModule("opentelemetry-proto", .{
        .root_source_file = b.path(proto_root ++ "/src/root.zig"),
        .target = info.target,
        .optimize = info.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_mod },
        },
    });
    try dependencies.put("opentelemetry-proto", proto_mod);

    _ = try addTestStep(b, proto_mod);
    _ = addUpdateTagStep(b);
    try addGenerateStep(b, info);
}

// Registers the "proto-generate" step, regenerating the Zig bindings under
// src/ from the proto-src submodule using protoc. Run it after updating
// the submodule (see the "update-tag" step).
fn addGenerateStep(b: *std.Build, info: CompilationInfo) !void {
    // protoc code generation is driven by the protobuf dependency's builder.
    const protobuf_dep = b.dependency("protobuf", .{
        .target = info.target,
        .optimize = info.optimize,
    });

    var source_files: [proto_files.len]std.Build.LazyPath = undefined;
    for (&source_files, proto_files) |*src, rel| {
        src.* = b.path(b.pathJoin(&.{ proto_root, "proto-src", rel }));
    }

    const protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, info.target, .{
        .destination_directory = b.path(proto_root ++ "/src"),
        .source_files = &source_files,
        .include_directories = &.{
            // Imports in proto files resolve against the submodule root.
            b.path(proto_root ++ "/proto-src"),
        },
    });
    protoc_step.verbose = info.optimize == .Debug;

    const step = b.step("proto-generate", "Regenerate proto bindings from the proto-src submodule (requires protoc)");
    step.dependOn(&protoc_step.step);
}

// Registers the "update-tag" step, moving the proto-src submodule (the official
// OpenTelemetry proto definitions) to a given tag, or the latest commit on its
// tracked branch. Regenerate the bindings from the updated submodule afterwards.
fn addUpdateTagStep(b: *std.Build) *std.Build.Step {
    const tag = b.option([]const u8, "tag",
        \\Tag of the OpenTelemetry proto submodule to check out.
        \\If not set, the latest commit on the tracked branch (main) is used.
    );

    // Pull the latest commit on the submodule's tracked branch.
    const update_remote = b.addSystemCommand(&.{ "git", "submodule", "update", "--remote" });

    const update_step = b.step("proto-update-tag", "Update the OpenTelemetry proto submodule to -Dtag (or latest)");

    if (tag) |t| {
        const update_to_tag = b.addSystemCommand(&.{
            "git",                           "submodule", "foreach",
            b.fmt("git checkout {s}", .{t}),
        });
        update_to_tag.step.dependOn(&update_remote.step);
        update_step.dependOn(&update_to_tag.step);
    } else {
        update_step.dependOn(&update_remote.step);
    }

    return update_step;
}

// Registers the "proto-test" step, building and running the proto unit tests.
fn addTestStep(b: *std.Build, proto_mod: *std.Build.Module) !*std.Build.Step {
    const step = b.step("proto-test", "Run opentelemetry-proto unit tests");

    const proto_tests = b.addTest(.{
        .root_module = proto_mod,
        .filters = b.args orelse &[0][]const u8{},
    });
    const run_proto_tests = b.addRunArtifact(proto_tests);
    step.dependOn(&run_proto_tests.step);

    return step;
}
