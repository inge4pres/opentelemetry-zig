const std = @import("std");
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies section
    // Benchmarks lib
    const benchmarks_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });

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
            // Signals
            "proto-src/opentelemetry/proto/common/v1/common.proto",
            "proto-src/opentelemetry/proto/resource/v1/resource.proto",
            "proto-src/opentelemetry/proto/metrics/v1/metrics.proto",
            "proto-src/opentelemetry/proto/trace/v1/trace.proto",
            "proto-src/opentelemetry/proto/logs/v1/logs.proto",
            // collector types for OTLP
            "proto-src/opentelemetry/proto/collector/metrics/v1/metrics_service.proto",
            "proto-src/opentelemetry/proto/collector/trace/v1/trace_service.proto",
            "proto-src/opentelemetry/proto/collector/logs/v1/logs_service.proto",
        },
        .include_directories = &.{
            // Importsin proto files requires that the top-level directory
            // containing te proto files is included
            "proto-src/",
        },
    });

    // Debug protoc generation in all builds
    protoc_step.verbose = true;

    const gen_proto = b.step("gen-proto", "Generates Zig files from protobuf definitions");
    gen_proto.dependOn(&protoc_step.step);

    const sdk_lib = b.addStaticLibrary(.{
        .name = "opentelemetry-sdk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdk.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .unwind_tables = .sync,
        }),
    });

    sdk_lib.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));

    b.installArtifact(sdk_lib);

    // Providing a way for the user to request running the unit tests.
    const test_step = b.step("test", "Run unit tests");

    // Creates a step for unit testing the SDK.
    // This only builds the test executable but does not run it.
    const sdk_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/sdk.zig"),
        .target = target,
        .optimize = optimize,
        // Allow passing test filter using the build args.
        .filters = b.args orelse &[0][]const u8{},
    });
    sdk_unit_tests.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));

    const run_sdk_unit_tests = b.addRunArtifact(sdk_unit_tests);

    test_step.dependOn(&run_sdk_unit_tests.step);

    // Examples
    const examples_step = b.step("examples", "Build and run all examples");
    examples_step.dependOn(&sdk_lib.step);

    // TODO add examples for other signals
    const metrics_examples = buildExamples(b, "examples/metrics", sdk_lib.root_module) catch |err| {
        std.debug.print("Error building metrics examples: {}\n", .{err});
        return;
    };
    defer b.allocator.free(metrics_examples);
    for (metrics_examples) |step| {
        const run_metrics_example = b.addRunArtifact(step);
        examples_step.dependOn(&run_metrics_example.step);
    }

    // Benchmarks
    const benchmarks_step = b.step("benchmarks", "Build and run all benchmarks");
    benchmarks_step.dependOn(&sdk_lib.step);

    const benchmark_mod = benchmarks_dep.module("zbench");

    const metrics_benchmarks = buildBenchmarks(b, "benchmarks/metrics", sdk_lib.root_module, benchmark_mod) catch |err| {
        std.debug.print("Error building metrics benchmarks: {}\n", .{err});
        return;
    };
    defer b.allocator.free(metrics_benchmarks);
    for (metrics_benchmarks) |step| {
        const run_metrics_benchmark = b.addRunArtifact(step);
        benchmarks_step.dependOn(&run_metrics_benchmark.step);
    }
}

fn buildExamples(b: *std.Build, base_dir: []const u8, otel_mod: *std.Build.Module) ![]*std.Build.Step.Compile {
    var exes = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    errdefer exes.deinit();

    var ex_dir = try std.fs.cwd().openDir(base_dir, .{ .iterate = true });
    defer ex_dir.close();

    var ex_dir_iter = ex_dir.iterate();
    while (try ex_dir_iter.next()) |file| {
        // Get the file name.
        // If it doesn't end in 'zig' then ignore.
        const index = std.mem.lastIndexOfScalar(u8, file.name, '.') orelse continue;
        if (index == 0) continue; // discard dotfiles
        if (!std.mem.eql(u8, file.name[index + 1 ..], "zig")) continue;

        const name = file.name[0..index];
        const example = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(try std.fs.path.join(b.allocator, &.{ base_dir, file.name })),
            .target = otel_mod.resolved_target.?,
            // We set the optimization level to ReleaseSafe for examples
            // because we want to have safety checks, and execute assertions.
            .optimize = .ReleaseSafe,
        });
        example.root_module.addImport("opentelemetry-sdk", otel_mod);
        try exes.append(example);
    }

    return exes.toOwnedSlice();
}

fn buildBenchmarks(
    b: *std.Build,
    base_dir: []const u8,
    otel_mod: *std.Build.Module,
    benchmark_mod: *std.Build.Module,
) ![]*std.Build.Step.Compile {
    var bench_tests = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    errdefer bench_tests.deinit();

    var test_dir = try std.fs.cwd().openDir(base_dir, .{ .iterate = true });
    defer test_dir.close();

    var iter = test_dir.iterate();
    while (try iter.next()) |file| {
        // Get the file name.
        // If it doesn't end in 'zig' then ignore.
        const index = std.mem.lastIndexOfScalar(u8, file.name, '.') orelse continue;
        if (index == 0) continue; // discard dotfiles
        if (!std.mem.eql(u8, file.name[index + 1 ..], "zig")) continue;

        const name = file.name[0..index];
        const benchmark = b.addTest(.{
            .name = name,
            .root_source_file = b.path(try std.fs.path.join(b.allocator, &.{ base_dir, file.name })),
            .target = otel_mod.resolved_target.?,
            // We set the optimization level to ReleaseFast for benchmarks
            // because we want to have the best performance.
            .optimize = .ReleaseFast,
        });
        benchmark.root_module.addImport("opentelemetry-sdk", otel_mod);
        benchmark.root_module.addImport("benchmark", benchmark_mod);

        try bench_tests.append(benchmark);
    }

    return bench_tests.toOwnedSlice();
}
