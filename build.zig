const std = @import("std");
const protobuf = @import("protobuf");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Protobuf code generation from the OpenTelemetry proto files.
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    const protoc_step = protobuf.RunProtocStep.create(b, protobuf_dep.builder, target, .{
        // Output directory for the generated zig files
        .destination_directory = b.path("src"),
        .source_files = &.{
            // Add more protobuf definitions as the API grows
            "proto-src/opentelemetry/proto/common/v1/common.proto",
            "proto-src/opentelemetry/proto/resource/v1/resource.proto",
            "proto-src/opentelemetry/proto/metrics/v1/metrics.proto",
        },
        .include_directories = &.{
            // Importsin proto files requires that the top-level directory
            // containing te proto files is included
            "proto-src/",
        },
    });

    // debug protoc generation
    protoc_step.verbose = true;

    const gen_proto = b.step("gen-proto", "generates zig files from protocol buffer definitions");
    gen_proto.dependOn(&protoc_step.step);

    const sdk_lib = b.addStaticLibrary(.{
        .name = "opentelemetry-sdk",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/sdk.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
        .unwind_tables = true,
    });

    sdk_lib.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(sdk_lib);

    // Providing a way for the user to request running the unit tests.
    const test_step = b.step("test", "Run unit tests");

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const sdk_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/sdk.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &[0][]const u8{},
    });
    sdk_unit_tests.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));

    const run_sdk_unit_tests = b.addRunArtifact(sdk_unit_tests);

    test_step.dependOn(&run_sdk_unit_tests.step);
}
