const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_verbose = b.option(bool, "test-verbose", "Show verbose test output") orelse false;
    const test_fail_first = b.option(bool, "test-fail-first", "Stop on first test failure") orelse false;
    const test_show_logs = b.option(bool, "test-show-logs", "Show captured log output for tests") orelse false;
    const benchmark_output = b.option([]const u8, "benchmark-output", "Path to write benchmark results to a file");
    const benchmark_debug = b.option(bool, "benchmark-debug", "Enable debug build mode for benchmarks") orelse false;

    // Dependencies section
    // Benchmarks lib
    const benchmarks_dep = b.dependency("zbench", .{});

    // OpenTelemetry proto package ships protobuf as a dependency so we'll use it.
    const otel_pb_dep = b.dependency("opentelemetry_proto", .{
        .optimize = optimize,
        .target = target,
    });
    const otel_proto_mod = otel_pb_dep.module("opentelemetry-proto");
    const protobuf_mod = otel_pb_dep.builder.dependency("protobuf", .{
        .optimize = optimize,
        .target = target,
    }).module("protobuf");

    // TODO: remove when 0.16.0 is released
    // zlib for gzip compression
    // Build our own zlib library using the upstream source from madler/zlib
    // Use lazyDependency to avoid executing the incompatible build.zig from the dependency
    const zlib_upstream = b.lazyDependency("zlib", .{}) orelse return error.MissingZlibDependency;
    const zlib_lib = b.addLibrary(.{
        .name = "z",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    zlib_lib.linkLibC();
    zlib_lib.addIncludePath(zlib_upstream.path(""));
    zlib_lib.addCSourceFiles(.{
        .root = zlib_upstream.path(""),
        .files = &.{
            "adler32.c",
            "compress.c",
            "crc32.c",
            "deflate.c",
            "gzclose.c",
            "gzlib.c",
            "gzread.c",
            "gzwrite.c",
            "inflate.c",
            "infback.c",
            "inftrees.c",
            "inffast.c",
            "trees.c",
            "uncompr.c",
            "zutil.c",
        },
        .flags = &.{
            "-DHAVE_SYS_TYPES_H",
            "-DHAVE_STDINT_H",
            "-DHAVE_STDDEF_H",
            "-DZ_HAVE_UNISTD_H",
            "-fno-sanitize=undefined", // Disable UBSan for C code to avoid linking issues
        },
    });

    // Modules section
    const sdk_mod = b.addModule("sdk", .{
        .root_source_file = b.path("src/sdk.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
        .unwind_tables = .sync,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_mod },
            .{ .name = "opentelemetry-proto", .module = otel_proto_mod },
        },
    });

    const sdk_lib = b.addLibrary(.{
        .name = "opentelemetry-sdk",
        .root_module = sdk_mod,
    });
    sdk_lib.linkLibrary(zlib_lib); // TODO: remove when 0.16.0 is released

    b.installArtifact(sdk_lib);

    // Providing a way for the user to request running the unit tests.
    const test_step = b.step("test", "Run unit tests");

    // Creates a step for unit testing the SDK.
    // This only builds the test executable but does not run it.
    const sdk_unit_tests = b.addTest(.{
        .root_module = sdk_mod,
        // Use custom test runner to capture log output
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
        // Allow passing test filter using the build args.
        .filters = b.args orelse &[0][]const u8{},
    });
    sdk_unit_tests.linkLibrary(zlib_lib); // TODO: remove when 0.16.0 is released

    // Pass test options as build options
    const test_options = b.addOptions();
    test_options.addOption(bool, "verbose", test_verbose);
    test_options.addOption(bool, "fail_first", test_fail_first);
    test_options.addOption(bool, "show_logs", test_show_logs);
    sdk_unit_tests.root_module.addOptions("test_options", test_options);

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
            .{ .name = "protobuf", .module = protobuf_mod },
            .{ .name = "opentelemetry-proto", .module = otel_proto_mod },
        },
    });
    // TODO add examples for other signals

    const examples_dirs: []const []const u8 = &.{ "metrics", "trace", "logs", "baggage", "propagation" };
    for (examples_dirs) |example_dir| {
        const example = buildExamples(
            b,
            b.path(b.pathJoin(&.{ "examples", example_dir })),
            sdk_mod,
            otel_stub_mod,
            otel_proto_mod,
            examples_filter,
        ) catch |err| {
            std.debug.print("Error building metrics examples: {}\n", .{err});
            return err;
        };
        defer b.allocator.free(example);
        for (example) |step| {
            const run_example = b.addRunArtifact(step);
            examples_step.dependOn(&run_example.step);
        }
    }

    // Benchmarks
    const benchmarks_step = b.step("benchmarks", "Build and run all benchmarks");

    const benchmark_mod = benchmarks_dep.module("zbench");

    const benchmarked_signals: []const []const u8 = &.{ "logs", "metrics", "trace" };
    for (benchmarked_signals) |signal| {
        const signal_benchmarks = buildBenchmarks(b, b.path(b.pathJoin(&.{ "benchmarks", signal })), sdk_mod, benchmark_mod, benchmark_debug) catch |err| {
            std.debug.print("Error building {s} benchmarks: {}\n", .{ signal, err });
            return err;
        };
        defer b.allocator.free(signal_benchmarks);
        for (signal_benchmarks) |step| {
            const run_signal_benchmark = b.addRunArtifact(step);

            // If output file is specified, redirect stderr to file
            if (benchmark_output) |output_path| {
                // Set stderr to write to file
                run_signal_benchmark.setEnvironmentVariable("BENCHMARK_OUTPUT_FILE", output_path);
            }

            benchmarks_step.dependOn(&run_signal_benchmark.step);
        }
    }

    // Integration tests step
    const integration_step = b.step("integration", "Run integration tests (requires Docker)");

    const integration_tests = buildIntegrationTests(b, b.path("integration_tests"), sdk_mod) catch |err| {
        std.debug.print("Error building integration tests: {}\n", .{err});
        return err;
    };
    defer b.allocator.free(integration_tests);
    for (integration_tests) |step| {
        const run_integration_test = b.addRunArtifact(step);
        integration_step.dependOn(&run_integration_test.step);
    }

    // Documentation webiste with autodoc
    const sdk_docs = b.addObject(.{
        .name = "sdk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdk.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = sdk_docs.getEmittedDocs(),
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
    var exes: std.ArrayList(*std.Build.Step.Compile) = .{};
    errdefer exes.deinit(b.allocator);

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
            try exes.append(b.allocator, b.addExecutable(.{
                .name = name,
                .root_module = b_mod,
            }));
        }
    }

    return exes.toOwnedSlice(b.allocator);
}

fn buildBenchmarks(
    b: *std.Build,
    bench_dir: std.Build.LazyPath,
    otel_mod: *std.Build.Module,
    benchmark_mod: *std.Build.Module,
    debug_mode: bool,
) ![]*std.Build.Step.Compile {
    var bench_tests: std.ArrayList(*std.Build.Step.Compile) = .{};
    errdefer bench_tests.deinit(b.allocator);

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
                .optimize = if (debug_mode) .Debug else .ReleaseFast,
                .strip = !debug_mode,
                .imports = &.{
                    .{ .name = "opentelemetry-sdk", .module = otel_mod },
                    .{ .name = "benchmark", .module = benchmark_mod },
                },
            });

            const test_step = b.addTest(.{
                .name = name,
                .root_module = b_mod,
                // Allow passing benchmark filter using the build args.
                .filters = b.args orelse &[0][]const u8{},
            });

            try bench_tests.append(b.allocator, test_step);
        }
    }

    return bench_tests.toOwnedSlice(b.allocator);
}

fn buildIntegrationTests(
    b: *std.Build,
    integration_dir: std.Build.LazyPath,
    otel_mod: *std.Build.Module,
) ![]*std.Build.Step.Compile {
    var integration_tests = std.ArrayList(*std.Build.Step.Compile){};
    errdefer integration_tests.deinit(b.allocator);

    // Create common module for shared integration test utilities
    const common_path = try integration_dir.join(b.allocator, "common.zig");
    const common_mod = b.createModule(.{
        .root_source_file = common_path,
        .target = otel_mod.resolved_target.?,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "opentelemetry-sdk", .module = otel_mod },
        },
    });

    var test_dir = try integration_dir.getPath3(b, null).openDir("", .{ .iterate = true });
    defer test_dir.close();

    var iter = test_dir.iterate();
    while (try iter.next()) |file| {
        if (getZigFileName(file.name)) |name| {
            // Skip common.zig as it's not a test executable
            if (std.mem.eql(u8, name, "common")) continue;

            // If integration filter is specified, skip non-matching tests
            const integration_filter = b.args;

            const file_name = try integration_dir.join(b.allocator, file.name);
            if (integration_filter) |filter| {
                for (filter) |filter_entry| {
                    if (std.mem.eql(u8, name, filter_entry)) {
                        const b_mod = b.createModule(.{
                            .root_source_file = file_name,
                            .target = otel_mod.resolved_target.?,
                            // Use ReleaseSafe for integration tests to have safety checks
                            .optimize = .ReleaseSafe,
                            .imports = &.{
                                .{ .name = "opentelemetry-sdk", .module = otel_mod },
                                .{ .name = "common", .module = common_mod },
                            },
                        });

                        try integration_tests.append(b.allocator, b.addExecutable(.{
                            .name = name,
                            .root_module = b_mod,
                        }));
                    }
                }
            } else {
                const b_mod = b.createModule(.{
                    .root_source_file = file_name,
                    .target = otel_mod.resolved_target.?,
                    // Use ReleaseSafe for integration tests to have safety checks
                    .optimize = .ReleaseSafe,
                    .imports = &.{
                        .{ .name = "opentelemetry-sdk", .module = otel_mod },
                        .{ .name = "common", .module = common_mod },
                    },
                });

                try integration_tests.append(b.allocator, b.addExecutable(.{
                    .name = name,
                    .root_module = b_mod,
                }));
            }
        }
    }

    return integration_tests.toOwnedSlice(b.allocator);
}

fn getZigFileName(file_name: []const u8) ?[]const u8 {
    // Get the file name without extension, checking if it ends with '.zig'.
    // If it doesn't end in 'zig' then ignore.
    const index = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return null;
    if (index == 0) return null; // discard dotfiles
    if (!std.mem.eql(u8, file_name[index + 1 ..], "zig")) return null;
    return file_name[0..index];
}
