const std = @import("std");
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const benchmark_output = b.option([]const u8, "benchmark-output", "Path to write benchmark results to a file");
    const benchmark_filter = b.option([]const u8, "benchmark-filter", "Filter to run only specific benchmarks");

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

    // Protobuf-generated code gets its own internal module
    const proto_mod = b.createModule(.{
        .root_source_file = b.path("src/opentelemetry/proto/proto.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_dep.module("protobuf") },
        },
    });

    const sdk_mod = b.addModule("sdk", .{
        .root_source_file = b.path("src/sdk.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
        .unwind_tables = .sync,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_dep.module("protobuf") },
            .{ .name = "opentelemetry-proto", .module = proto_mod },
        },
    });

    const sdk_lib = b.addLibrary(.{
        .name = "opentelemetry-sdk",
        .root_module = sdk_mod,
    });

    b.installArtifact(sdk_lib);

    // Providing a way for the user to request running the unit tests.
    const test_step = b.step("test", "Run unit tests");

    // Creates a step for unit testing the SDK.
    // This only builds the test executable but does not run it.
    const sdk_unit_tests = b.addTest(.{
        .root_module = sdk_mod,
        .target = target,
        .optimize = optimize,
        // Allow passing test filter using the build args.
        .filters = b.args orelse &[0][]const u8{},
    });

    const run_sdk_unit_tests = b.addRunArtifact(sdk_unit_tests);

    test_step.dependOn(&run_sdk_unit_tests.step);

    // Examples
    const examples_step = b.step("examples", "Build and run all examples");
    const examples_filter = b.option([]const u8, "examples-filter", "Filter examples to build");

    // Attach an OTLP stub module to allow examples to use it.
    const otel_stub_mod = b.createModule(.{
        .root_source_file = b.path("examples/otlp_stub/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "opentelemetry-sdk", .module = sdk_mod },
            .{ .name = "protobuf", .module = protobuf_dep.module("protobuf") },
            .{ .name = "opentelemetry-proto", .module = proto_mod },
        },
    });
    // TODO add examples for other signals
    const metrics_examples = buildExamples(
        b,
        b.path(b.pathJoin(&.{ "examples", "metrics" })),
        sdk_mod,
        otel_stub_mod,
        proto_mod,
        examples_filter,
    ) catch |err| {
        std.debug.print("Error building metrics examples: {}\n", .{err});
        return err;
    };
    defer b.allocator.free(metrics_examples);
    for (metrics_examples) |step| {
        const run_metrics_example = b.addRunArtifact(step);
        examples_step.dependOn(&run_metrics_example.step);
    }

    // Benchmarks
    const benchmarks_step = b.step("benchmarks", "Build and run all benchmarks");

    const benchmark_mod = benchmarks_dep.module("zbench");

    const metrics_benchmarks = buildBenchmarks(
        b,
        b.path(b.pathJoin(&.{ "benchmarks", "metrics" })),
        sdk_mod,
        benchmark_mod,
        benchmark_filter,
    ) catch |err| {
        std.debug.print("Error building metrics benchmarks: {}\n", .{err});
        return err;
    };
    defer b.allocator.free(metrics_benchmarks);
    for (metrics_benchmarks) |step| {
        const run_metrics_benchmark = b.addRunArtifact(step);

        // If output file is specified, redirect stderr to file
        if (benchmark_output) |output_path| {
            // Set stderr to write to file
            run_metrics_benchmark.setEnvironmentVariable("BENCHMARK_OUTPUT_FILE", output_path);
        }

        benchmarks_step.dependOn(&run_metrics_benchmark.step);
    }

    // Documentation webiste with autodoc
    const install_docs = b.addInstallDirectory(.{
        .source_dir = sdk_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Copy documentation artifacts to prefix path");
    docs_step.dependOn(&sdk_lib.step);
    docs_step.dependOn(&install_docs.step);
}

fn buildExamples(
    b: *std.Build,
    examples_dir: std.Build.LazyPath,
    otel_sdk_mod: *std.Build.Module,
    otlp_stub_mod: *std.Build.Module,
    proto_mod: *std.Build.Module,
    name_filter: ?[]const u8,
) ![]*std.Build.Step.Compile {
    var exes = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    errdefer exes.deinit();

    var ex_dir = try examples_dir.getPath3(b, null).openDir("", .{ .iterate = true });
    defer ex_dir.close();

    var ex_dir_iter = ex_dir.iterate();
    while (try ex_dir_iter.next()) |file| {
        if (getZigFileName(file.name)) |name| {
            // Discard the modules that do not match the filter
            if (name_filter) |filter| {
                if (std.mem.indexOf(u8, name, filter) == null) continue;
            }
            const file_name = try examples_dir.join(b.allocator, file.name);

            const b_mod = b.createModule(.{
                .root_source_file = file_name,
                .target = otel_sdk_mod.resolved_target.?,
                // We set the optimization level to ReleaseSafe for examples
                // because we want to have safety checks, and execute assertions.
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "opentelemetry-sdk", .module = otel_sdk_mod },
                    .{ .name = "otlp-stub", .module = otlp_stub_mod },
                    .{ .name = "opentelemetry-proto", .module = proto_mod },
                },
            });
            try exes.append(b.addExecutable(.{
                .name = name,
                .root_module = b_mod,
            }));
        }
    }

    return exes.toOwnedSlice();
}

fn buildBenchmarks(
    b: *std.Build,
    bench_dir: std.Build.LazyPath,
    otel_mod: *std.Build.Module,
    benchmark_mod: *std.Build.Module,
    benchmark_filter: ?[]const u8,
) ![]*std.Build.Step.Compile {
    var bench_tests = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    errdefer bench_tests.deinit();

    var test_dir = try bench_dir.getPath3(b, null).openDir("", .{ .iterate = true });
    defer test_dir.close();

    var iter = test_dir.iterate();
    while (try iter.next()) |file| {
        if (getZigFileName(file.name)) |name| {
            const file_name = try bench_dir.join(b.allocator, file.name);

            const b_mod = b.createModule(.{
                .root_source_file = file_name,
                .target = otel_mod.resolved_target.?,
                // We set the optimization level to ReleaseFast for benchmarks
                // because we want to have the best performance.
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "opentelemetry-sdk", .module = otel_mod },
                    .{ .name = "benchmark", .module = benchmark_mod },
                },
            });

            const test_step = b.addTest(.{
                .name = name,
                .root_module = b_mod,
            });

            // Apply benchmark filter if provided
            if (benchmark_filter) |filter| {
                test_step.filters = b.allocator.dupe([]const u8, &.{filter}) catch unreachable;
            }

            try bench_tests.append(test_step);
        }
    }

    return bench_tests.toOwnedSlice();
}

fn getZigFileName(file_name: []const u8) ?[]const u8 {
    // Get the file name without extension, checking if it ends with '.zig'.
    // If it doesn't end in 'zig' then ignore.
    const index = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return null;
    if (index == 0) return null; // discard dotfiles
    if (!std.mem.eql(u8, file_name[index + 1 ..], "zig")) return null;
    return file_name[0..index];
}
